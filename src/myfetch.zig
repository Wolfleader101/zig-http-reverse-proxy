const std = @import("std");
const http = std.http;
const Client = std.http.Client;
const FetchOptions = std.http.Client.FetchOptions;
const Uri = std.Uri;
const assert = std.debug.assert;

/// Perform a one-shot HTTP request with the provided options.
///
/// This function is threadsafe.
pub fn my_fetch(client: *Client, options: FetchOptions) !std.http.Client.Response {
    const uri = switch (options.location) {
        .url => |u| try Uri.parse(u),
        .uri => |u| u,
    };
    var server_header_buffer: [16 * 1024]u8 = undefined;

    const method: http.Method = options.method orelse
        if (options.payload != null) .POST else .GET;

    var req = try client.open(method, uri, .{
        .server_header_buffer = options.server_header_buffer orelse &server_header_buffer,
        .redirect_behavior = options.redirect_behavior orelse
            if (options.payload == null) @enumFromInt(3) else .unhandled,
        .headers = options.headers,
        .extra_headers = options.extra_headers,
        .privileged_headers = options.privileged_headers,
        .keep_alive = options.keep_alive,
    });
    defer req.deinit();

    if (options.payload) |payload| req.transfer_encoding = .{ .content_length = payload.len };

    try req.send();

    if (options.payload) |payload| try req.writeAll(payload);

    try req.finish();
    try req.wait();

    switch (options.response_storage) {
        .ignore => {
            // Take advantage of request internals to discard the response body
            // and make the connection available for another request.
            req.response.skip = true;
            // assert(try req.transferRead(&.{}) == 0); // No buffer is necessary when skipping.
        },
        .dynamic => |list| {
            const max_append_size = options.max_append_size orelse 2 * 1024 * 1024;
            try req.reader().readAllArrayList(list, max_append_size);
        },
        .static => |list| {
            const buf = b: {
                const buf = list.unusedCapacitySlice();
                if (options.max_append_size) |len| {
                    if (len < buf.len) break :b buf[0..len];
                }
                break :b buf;
            };
            list.items.len += try req.reader().readAll(buf);
        },
    }

    return req.response;
}
