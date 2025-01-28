const std = @import("std");
const myfetch = @import("myfetch.zig").my_fetch;

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

    // create an address which we will listen on
    var addr = std.net.Address.parseIp4("127.0.0.1", 6969) catch |err| {
        try stdout.print("Error Parsing Ip4: {}\n", .{err});
        return;
    };

    // create a server and listen on the address
    var netServer = addr.listen(.{ .reuse_address = true }) catch |err| {
        try stdout.print("Error Listening: {}\n", .{err});
        return;
    };

    // defer the server deinit to ensure it is closed
    defer netServer.deinit();

    try stdout.print("Reverse Proxy started on http://{}\n", .{addr});

    // start the server to accept connections, "try" is used to propagate the error
    try startServer(&netServer);
}

fn startServer(netServer: *std.net.Server) !void {
    var threadPoolAllocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = threadPoolAllocator.deinit();

    var threadPool: std.Thread.Pool = undefined;
    try threadPool.init(std.Thread.Pool.Options{ .allocator = threadPoolAllocator.allocator(), .n_jobs = 4 });
    defer threadPool.deinit();

    while (true) {
        const conn = netServer.accept() catch |err| {
            std.debug.print("Error Accepting Connection: {}\n", .{err});
            continue;
        };

        threadPool.spawn(handleConnection, .{conn}) catch |err| {
            std.debug.print("Error Spawning Thread: {}\n", .{err});
        };
    }
}

fn handleConnection(conn: std.net.Server.Connection) void {
    defer conn.stream.close();

    var headerBuffer: [8 * 1024]u8 = undefined;

    var httpServer = std.http.Server.init(conn, &headerBuffer);

    var req = httpServer.receiveHead() catch |err| {
        std.debug.print("Error Receiving HTTP Head: {}\n", .{err});
        return;
    };

    handleThreadPoolRequest(&req);
}

const RedirectTarget = enum {
    api,
    static,
    pub fn str(self: RedirectTarget) []const u8 {
        switch (self) {
            RedirectTarget.api => return "api",
            RedirectTarget.static => return "static",
        }
    }
    pub fn toUrl(self: RedirectTarget) []const u8 {
        switch (self) {
            RedirectTarget.api => return "http://127.0.0.1:8000",
            RedirectTarget.static => return "http://127.0.0.1:8000",
        }
    }
};

fn handleThreadPoolRequest(req: *std.http.Server.Request) void {
    handleRequest(req) catch |err| {
        std.debug.print("Error Handling Request: {}\n", .{err});
    };
}

fn handleRequest(req: *std.http.Server.Request) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var proxyRes: std.http.Client.Response = undefined;

    var server_header_buffer: [16 * 1024]u8 = undefined;

    var responseStorage = std.ArrayList(u8).init(gpa.allocator());
    defer responseStorage.deinit();

    if (std.mem.indexOf(u8, req.head.target, RedirectTarget.api.str()) != null) {
        proxyRes = proxyRequest(req, RedirectTarget.api, &server_header_buffer, &responseStorage, gpa.allocator()) catch |err| {
            std.debug.print("Error Proxying Request: {}\n", .{err});
            req.respond(&.{}, .{ .status = .internal_server_error }) catch |err2| {
                std.debug.print("Error Responding: {}\n", .{err2});
            };
            return;
        };
    } else if (std.mem.indexOf(u8, req.head.target, RedirectTarget.static.str()) != null) {
        proxyRes = proxyRequest(req, RedirectTarget.static, &server_header_buffer, &responseStorage, gpa.allocator()) catch |err| {
            std.debug.print("Error Proxying Request: {}\n", .{err});
            req.respond(&.{}, .{ .status = .internal_server_error }) catch |err2| {
                std.debug.print("Error Responding: {}\n", .{err2});
            };
            return;
        };
    } else {
        req.respond("Not Found", .{ .status = .not_found }) catch |err| {
            std.debug.print("Error Responding: {}\n", .{err});
            return;
        };
        return;
    }

    // some headers must be set here and not as extra headers
    var filteredHeaders = std.ArrayList(std.http.Header).init(gpa.allocator());
    defer filteredHeaders.deinit();

    var it = proxyRes.iterateHeaders();

    while (it.next()) |header| {
        // filters out headers already set above
        // if (std.ascii.eqlIgnoreCase(header.name, "Content-Type")) {
        //     // std.debug.print("Skipping Content-Type (already set)\n", .{});
        //     continue;
        // }
        if (std.ascii.eqlIgnoreCase(header.name, "Content-Length")) {
            // std.debug.print("Skipping Content-Length (already set or handled)\n", .{});
            continue;
        }
        if (std.ascii.eqlIgnoreCase(header.name, "Transfer-Encoding")) {
            // std.debug.print("Skipping Transfer-Encoding (already set or chunked)\n", .{});
            continue;
        }
        if (std.ascii.eqlIgnoreCase(header.name, "Content-Encoding")) {
            // std.debug.print("Skipping Content-Encoding (already set)\n", .{});
            continue;
        }
        if (std.ascii.eqlIgnoreCase(header.name, "Connection")) {
            // std.debug.print("Skipping Connection (already set via keep-alive)\n", .{});
            continue;
        }

        // std.debug.print("Appending {s}: {s}\n", .{ header.name, header.value });
        filteredHeaders.append(header) catch |err| {
            std.debug.print("Error Appending Header: {}\n", .{err});
        };
    }

    req.respond(responseStorage.items, .{
        .version = proxyRes.version,
        .status = proxyRes.status,
        .reason = proxyRes.reason,
        .keep_alive = proxyRes.keep_alive,
        .extra_headers = filteredHeaders.items,
        .transfer_encoding = proxyRes.transfer_encoding,
        // .content_type = proxyRes.content_type,
        // ^^ Awaiting https://github.com/ziglang/zig/pull/22590
    }) catch |err| {
        std.debug.print("Error Responding: {}\n", .{err});
    };
}

fn proxyRequest(req: *std.http.Server.Request, target: RedirectTarget, serverHeaderBuffer: []u8, responseStorage: *std.ArrayList(u8), allocator: std.mem.Allocator) !std.http.Client.Response {

    // create a new connection to the target server
    var client = std.http.Client{
        .allocator = allocator,
    };
    defer client.deinit();

    const stripBody = req.head.method == .GET;

    var contentType: std.http.Client.Request.Headers.Value = undefined;
    if (req.head.content_type) |ct| {
        contentType = .{ .override = ct };
    } else {
        contentType = .default;
    }

    const contentLengthInt = req.head.content_length orelse 0;
    var buf: [32]u8 = undefined;
    const contentLength = try std.fmt.bufPrint(&buf, "{}", .{contentLengthInt});

    const extraHeaders = [_]std.http.Header{
        .{ .name = "Content-Length", .value = contentLength },
    };

    const reader = try req.reader();
    const body = try reader.readAllAlloc(allocator, contentLengthInt);
    defer allocator.free(body);

    var locBuf: [1024]u8 = undefined;
    const locationUrl = try std.fmt.bufPrint(&locBuf, "{s}{s}", .{ target.toUrl(), req.head.target });

    // send the request to the target server
    // receive the response from the target server
    const fetchRes = myfetch(&client, .{
        .location = .{ .url = locationUrl },
        .method = req.head.method,
        .headers = .{ .content_type = contentType },
        .extra_headers = &extraHeaders,
        .payload = if (stripBody) null else body,
        .response_storage = .{ .dynamic = responseStorage },
        .server_header_buffer = serverHeaderBuffer,
    }) catch |err| {
        std.debug.print("Error Fetching: {}\n", .{err});
        return err;
    };

    return fetchRes;
}
