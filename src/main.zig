const std = @import("std");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    var addr = std.net.Address.parseIp4("127.0.0.1", 6969) catch |err| {
        try stdout.print("Error Parsing Ip4: {}\n", .{err});
        return;
    };

    var netServer = addr.listen(.{ .reuse_address = true }) catch |err| {
        try stdout.print("Error Listening: {}\n", .{err});
        return;
    };

    defer netServer.deinit();

    startServer(netServer);

}

fn startServer(netServer: *std.net.Server) void {
    try stdout.print("Reverse Proxy started on http://{}\n", .{addr});

    while (netServer.accept()) |conn| {
        defer conn.stream.close();
        var headerBuffer: [2048]u8 = undefined;

        var httpServer = std.http.Server.init(conn, &headerBuffer);

        var req = httpServer.receiveHead() catch |err| {
            std.debug.print("Error Receiving HTTP Head: {}\n", .{err});
            continue;
        };

        handleRequest(&req) catch |err| {
            std.debug.print("Error Handling Request: {}\n", .{err});
        };
        
    } else |err| {
        std.debug.print("Connection to client error: {}\n", .{err});
    }
}

fn handleRequest(req: *std.http.Server.Request) !void {
    try req.respond("Hello World", .{});
}

test ""