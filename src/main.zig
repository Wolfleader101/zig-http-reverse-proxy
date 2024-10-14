const std = @import("std");
const myfetch = @import("myfetch.zig");

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
    tcp_accept: while (true) {
        var conn = netServer.accept() catch |err| {
            std.debug.print("Error Accepting Connection: {}\n", .{err});
            continue;
        };

        defer conn.stream.close();

        var headerBuffer: [8000]u8 = undefined;

        var httpServer = std.http.Server.init(conn, &headerBuffer);

        while (httpServer.state == .ready) {
            var req = httpServer.receiveHead() catch |err| {
                std.debug.print("Error Receiving HTTP Head: {}\n", .{err});
                continue :tcp_accept;
            };

            var thread = std.Thread.spawn(.{}, handleRequest, .{&req}) catch |err| {
                std.debug.print("Error Spawning Thread: {}\n", .{err});
                continue :tcp_accept;
            };

            defer thread.join();
        }
    }
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

const ProxyResponse = struct {
    res: std.http.Client.Response,
    body: std.ArrayList(u8),
};

fn handleRequest(req: *std.http.Server.Request) void {
    // create a new heap allocator

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var proxyRes: ProxyResponse = undefined;
    defer proxyRes.body.deinit();
    if (std.mem.indexOf(u8, req.head.target, RedirectTarget.api.str()) != null) {
        proxyRes = proxyRequest(req, RedirectTarget.api, gpa.allocator()) catch |err| {
            std.debug.print("Error Proxying Request: {}\n", .{err});
            return;
        };
    } else if (std.mem.indexOf(u8, req.head.target, RedirectTarget.static.str()) != null) {
        proxyRes = proxyRequest(req, RedirectTarget.static, gpa.allocator()) catch |err| {
            std.debug.print("Error Proxying Request: {}\n", .{err});
            return;
        };
    } else {
        req.respond("Not Found", .{ .status = .not_found }) catch |err| {
            std.debug.print("Error Responding: {}\n", .{err});
            return;
        };
    }

    req.head.version = proxyRes.res.version;
    req.head.content_type = proxyRes.res.content_type;
    req.head.keep_alive = proxyRes.res.keep_alive;
    req.head.content_length = proxyRes.res.content_length;
    req.head.transfer_encoding = proxyRes.res.transfer_encoding;
    req.head.transfer_compression = proxyRes.res.transfer_compression;

    const extraHeaders = [_]std.http.Header{
        .{ .name = "Content-Type", .value = proxyRes.res.content_type orelse "text/plain" },
    };

    // print the content type of the response
    std.debug.print("Content-Type: {s}\n", .{proxyRes.res.content_type.?});

    req.respond(proxyRes.body.items, .{ .status = proxyRes.res.status, .extra_headers = &extraHeaders }) catch |err| {
        std.debug.print("Error Responding: {}\n", .{err});
    };
}

fn proxyRequest(req: *std.http.Server.Request, target: RedirectTarget, allocator: std.mem.Allocator) !ProxyResponse {

    // create a new connection to the target server
    var client = std.http.Client{
        .allocator = allocator,
    };
    defer client.deinit();

    var responseStorage = std.ArrayList(u8).init(allocator);

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
    const fetchRes = myfetch.my_fetch(&client, .{
        .location = .{ .url = locationUrl },
        .method = req.head.method,
        .headers = .{ .content_type = contentType },
        .extra_headers = &extraHeaders,
        .payload = if (stripBody) null else body,
        .response_storage = .{ .dynamic = &responseStorage },
    }) catch |err| {
        std.debug.print("Error Fetching: {}\n", .{err});
        return err;
    };

    const proxyRes = ProxyResponse{
        .res = fetchRes.response,
        .body = responseStorage,
    };
    // respond to the client with the response from the target server (headers and body)
    return proxyRes;
}
