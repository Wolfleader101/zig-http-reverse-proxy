const std = @import("std");

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
    while (netServer.accept()) |conn| {
        defer conn.stream.close();
        var headerBuffer: [2048]u8 = undefined;

        var httpServer = std.http.Server.init(conn, &headerBuffer);

        var req = httpServer.receiveHead() catch |err| {
            std.debug.print("Error Receiving HTTP Head: {}\n", .{err});
            continue;
        };

        {
            var thread = std.Thread.spawn(.{}, handleRequest, .{&req}) catch |err| {
                std.debug.print("Error Spawning Thread: {}\n", .{err});
                return err;
            };

            defer thread.join();
        }
    } else |err| {
        std.debug.print("Connection to client error: {}\n", .{err});
    }
}

const RedirectUrl = enum([1024]u8) {
    api = "http://localhost:8080",
    static = "http://localhost:8081",
};

fn handleRequest(req: *std.http.Server.Request) void {
    var responseContent: [1024]u8 = undefined;
    const responseContentLen = req.head.target.len;

    const ApiTarget = "api";
    const StaticTarget = "static";

    if (std.mem.indexOf(u8, req.head.target, ApiTarget)) |idx| {}

    _ = std.fmt.bufPrint(responseContent[0..], "{s}", .{req.head.target}) catch |err| {
        std.debug.print("Error Formatting Response: {}\n", .{err});
        return;
    };

    req.respond(responseContent[0..responseContentLen], .{}) catch |err| {
        std.debug.print("Error Responding: {}\n", .{err});
    };
}

fn proxyRequest(req: *std.http.Server.Request, target: RedirectUrl) !std.http.Client.Response {

    // create a new heap allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer gpa.deinit();

    // create a new connection to the target server
    var client = std.http.Client{
        .allocator = gpa.allocator(),
    };
    defer client.deinit();

    var responseStorage = std.ArrayList(u8){};

    var fetchRes = client.fetch(.{
        .method = req.head.method,
        .target = target,
        .headers = req.head.headers,
        .body = req.body,
        .response_storage = .{ .dynamic = &responseStorage },
    }) catch |err| {
        return err;
    };

    var cres = std.http.Client.Response{
        .
    }

    const res = std.http.Server.Response{
        .
    };
    

    // send the request to the target server

    // receive the response from the target server

    // respond to the client with the response from the target server
}
