const std = @import("std");

/// Huffman coding for HPACK (RFC 7541 Appendix B)
/// This implementation provides Huffman encoding and decoding for HTTP/2 header compression
pub const Error = error{
    InvalidHuffmanCode,
    BufferTooSmall,
    InvalidPadding,
};

/// Huffman code entry
pub const HuffmanCode = struct {
    bits: u32, // The bit pattern
    length: u5, // Number of bits (max 30 for longest code)
};

/// RFC 7541 Appendix B - Huffman Code Table
/// This is the canonical Huffman table for HPACK
pub const HUFFMAN_TABLE = [256]HuffmanCode{
    // 0-15
    .{ .bits = 0x1ff8, .length = 13 }, // 0
    .{ .bits = 0x7fffd8, .length = 23 }, // 1
    .{ .bits = 0xfffffe2, .length = 28 }, // 2
    .{ .bits = 0xfffffe3, .length = 28 }, // 3
    .{ .bits = 0xfffffe4, .length = 28 }, // 4
    .{ .bits = 0xfffffe5, .length = 28 }, // 5
    .{ .bits = 0xfffffe6, .length = 28 }, // 6
    .{ .bits = 0xfffffe7, .length = 28 }, // 7
    .{ .bits = 0xfffffe8, .length = 28 }, // 8
    .{ .bits = 0xffffea, .length = 24 }, // 9
    .{ .bits = 0x3ffffffc, .length = 30 }, // 10
    .{ .bits = 0xfffffe9, .length = 28 }, // 11
    .{ .bits = 0xfffffea, .length = 28 }, // 12
    .{ .bits = 0x3ffffffd, .length = 30 }, // 13
    .{ .bits = 0xfffffeb, .length = 28 }, // 14
    .{ .bits = 0xfffffec, .length = 28 }, // 15

    // 16-31
    .{ .bits = 0xfffffed, .length = 28 }, // 16
    .{ .bits = 0xfffffee, .length = 28 }, // 17
    .{ .bits = 0xfffffef, .length = 28 }, // 18
    .{ .bits = 0xffffff0, .length = 28 }, // 19
    .{ .bits = 0xffffff1, .length = 28 }, // 20
    .{ .bits = 0xffffff2, .length = 28 }, // 21
    .{ .bits = 0x3ffffffe, .length = 30 }, // 22
    .{ .bits = 0xffffff3, .length = 28 }, // 23
    .{ .bits = 0xffffff4, .length = 28 }, // 24
    .{ .bits = 0xffffff5, .length = 28 }, // 25
    .{ .bits = 0xffffff6, .length = 28 }, // 26
    .{ .bits = 0xffffff7, .length = 28 }, // 27
    .{ .bits = 0xffffff8, .length = 28 }, // 28
    .{ .bits = 0xffffff9, .length = 28 }, // 29
    .{ .bits = 0xffffffa, .length = 28 }, // 30
    .{ .bits = 0xffffffb, .length = 28 }, // 31

    // 32-47 (includes space=32, common punctuation)
    .{ .bits = 0x14, .length = 6 }, // 32: ' ' (space) - very common!
    .{ .bits = 0x3f8, .length = 10 }, // 33: '!'
    .{ .bits = 0x3f9, .length = 10 }, // 34: '"'
    .{ .bits = 0xffa, .length = 12 }, // 35: '#'
    .{ .bits = 0x1ff9, .length = 13 }, // 36: '$'
    .{ .bits = 0x15, .length = 6 }, // 37: '%'
    .{ .bits = 0xf8, .length = 8 }, // 38: '&'
    .{ .bits = 0x7fa, .length = 11 }, // 39: '\''
    .{ .bits = 0x3fa, .length = 10 }, // 40: '('
    .{ .bits = 0x3fb, .length = 10 }, // 41: ')'
    .{ .bits = 0xf9, .length = 8 }, // 42: '*'
    .{ .bits = 0x7fb, .length = 11 }, // 43: '+'
    .{ .bits = 0xfa, .length = 8 }, // 44: ','
    .{ .bits = 0x16, .length = 6 }, // 45: '-'
    .{ .bits = 0x17, .length = 6 }, // 46: '.'
    .{ .bits = 0x18, .length = 6 }, // 47: '/'

    // 48-63 (digits 0-9 and more punctuation)
    .{ .bits = 0x0, .length = 5 }, // 48: '0'
    .{ .bits = 0x1, .length = 5 }, // 49: '1'
    .{ .bits = 0x2, .length = 5 }, // 50: '2'
    .{ .bits = 0x19, .length = 6 }, // 51: '3'
    .{ .bits = 0x1a, .length = 6 }, // 52: '4'
    .{ .bits = 0x1b, .length = 6 }, // 53: '5'
    .{ .bits = 0x1c, .length = 6 }, // 54: '6'
    .{ .bits = 0x1d, .length = 6 }, // 55: '7'
    .{ .bits = 0x1e, .length = 6 }, // 56: '8'
    .{ .bits = 0x1f, .length = 6 }, // 57: '9'
    .{ .bits = 0x5c, .length = 7 }, // 58: ':'
    .{ .bits = 0xfb, .length = 8 }, // 59: ';'
    .{ .bits = 0x7ffc, .length = 15 }, // 60: '<'
    .{ .bits = 0x20, .length = 6 }, // 61: '='
    .{ .bits = 0xffb, .length = 12 }, // 62: '>'
    .{ .bits = 0x3fc, .length = 10 }, // 63: '?'

    // 64-79 (@ and uppercase A-O)
    .{ .bits = 0x1ffa, .length = 13 }, // 64: '@'
    .{ .bits = 0x21, .length = 6 }, // 65: 'A'
    .{ .bits = 0x5d, .length = 7 }, // 66: 'B'
    .{ .bits = 0x5e, .length = 7 }, // 67: 'C'
    .{ .bits = 0x5f, .length = 7 }, // 68: 'D'
    .{ .bits = 0x60, .length = 7 }, // 69: 'E'
    .{ .bits = 0x61, .length = 7 }, // 70: 'F'
    .{ .bits = 0x62, .length = 7 }, // 71: 'G'
    .{ .bits = 0x63, .length = 7 }, // 72: 'H'
    .{ .bits = 0x64, .length = 7 }, // 73: 'I'
    .{ .bits = 0x65, .length = 7 }, // 74: 'J'
    .{ .bits = 0x66, .length = 7 }, // 75: 'K'
    .{ .bits = 0x67, .length = 7 }, // 76: 'L'
    .{ .bits = 0x68, .length = 7 }, // 77: 'M'
    .{ .bits = 0x69, .length = 7 }, // 78: 'N'
    .{ .bits = 0x6a, .length = 7 }, // 79: 'O'

    // 80-95 (uppercase P-Z and more punctuation)
    .{ .bits = 0x6b, .length = 7 }, // 80: 'P'
    .{ .bits = 0x6c, .length = 7 }, // 81: 'Q'
    .{ .bits = 0x6d, .length = 7 }, // 82: 'R'
    .{ .bits = 0x6e, .length = 7 }, // 83: 'S'
    .{ .bits = 0x6f, .length = 7 }, // 84: 'T'
    .{ .bits = 0x70, .length = 7 }, // 85: 'U'
    .{ .bits = 0x71, .length = 7 }, // 86: 'V'
    .{ .bits = 0x72, .length = 7 }, // 87: 'W'
    .{ .bits = 0xfc, .length = 8 }, // 88: 'X'
    .{ .bits = 0x73, .length = 7 }, // 89: 'Y'
    .{ .bits = 0xfd, .length = 8 }, // 90: 'Z'
    .{ .bits = 0x1ffb, .length = 13 }, // 91: '['
    .{ .bits = 0x7fff0, .length = 19 }, // 92: '\\'
    .{ .bits = 0x1ffc, .length = 13 }, // 93: ']'
    .{ .bits = 0x3ffc, .length = 14 }, // 94: '^'
    .{ .bits = 0x22, .length = 6 }, // 95: '_'

    // 96-111 (` and lowercase a-o)
    .{ .bits = 0x7ffd, .length = 15 }, // 96: '`'
    .{ .bits = 0x3, .length = 5 }, // 97: 'a' - very common!
    .{ .bits = 0x23, .length = 6 }, // 98: 'b'
    .{ .bits = 0x4, .length = 5 }, // 99: 'c'
    .{ .bits = 0x24, .length = 6 }, // 100: 'd'
    .{ .bits = 0x5, .length = 5 }, // 101: 'e' - very common!
    .{ .bits = 0x25, .length = 6 }, // 102: 'f'
    .{ .bits = 0x26, .length = 6 }, // 103: 'g'
    .{ .bits = 0x27, .length = 6 }, // 104: 'h'
    .{ .bits = 0x6, .length = 5 }, // 105: 'i'
    .{ .bits = 0x74, .length = 7 }, // 106: 'j'
    .{ .bits = 0x75, .length = 7 }, // 107: 'k'
    .{ .bits = 0x28, .length = 6 }, // 108: 'l'
    .{ .bits = 0x29, .length = 6 }, // 109: 'm'
    .{ .bits = 0x2a, .length = 6 }, // 110: 'n'
    .{ .bits = 0x7, .length = 5 }, // 111: 'o'

    // 112-127 (lowercase p-z and more punctuation)
    .{ .bits = 0x2b, .length = 6 }, // 112: 'p'
    .{ .bits = 0x76, .length = 7 }, // 113: 'q'
    .{ .bits = 0x2c, .length = 6 }, // 114: 'r'
    .{ .bits = 0x8, .length = 5 }, // 115: 's'
    .{ .bits = 0x9, .length = 5 }, // 116: 't'
    .{ .bits = 0x2d, .length = 6 }, // 117: 'u'
    .{ .bits = 0x77, .length = 7 }, // 118: 'v'
    .{ .bits = 0x78, .length = 7 }, // 119: 'w'
    .{ .bits = 0x79, .length = 7 }, // 120: 'x'
    .{ .bits = 0x7a, .length = 7 }, // 121: 'y'
    .{ .bits = 0x7b, .length = 7 }, // 122: 'z'
    .{ .bits = 0x7ffe, .length = 15 }, // 123: '{'
    .{ .bits = 0x7fc, .length = 11 }, // 124: '|'
    .{ .bits = 0x3ffd, .length = 14 }, // 125: '}'
    .{ .bits = 0x1ffd, .length = 13 }, // 126: '~'
    .{ .bits = 0xffffffc, .length = 28 }, // 127: DEL

    // 128-255 (Extended ASCII - all use longer codes)
    .{ .bits = 0xfffe6, .length = 20 }, // 128
    .{ .bits = 0x3fffd2, .length = 22 }, // 129
    .{ .bits = 0xfffe7, .length = 20 }, // 130
    .{ .bits = 0xfffe8, .length = 20 }, // 131
    .{ .bits = 0x3fffd3, .length = 22 }, // 132
    .{ .bits = 0x3fffd4, .length = 22 }, // 133
    .{ .bits = 0x3fffd5, .length = 22 }, // 134
    .{ .bits = 0x7fffd9, .length = 23 }, // 135
    .{ .bits = 0x3fffd6, .length = 22 }, // 136
    .{ .bits = 0x7fffda, .length = 23 }, // 137
    .{ .bits = 0x7fffdb, .length = 23 }, // 138
    .{ .bits = 0x7fffdc, .length = 23 }, // 139
    .{ .bits = 0x7fffdd, .length = 23 }, // 140
    .{ .bits = 0x7fffde, .length = 23 }, // 141
    .{ .bits = 0xffffeb, .length = 24 }, // 142
    .{ .bits = 0x7fffdf, .length = 23 }, // 143
    .{ .bits = 0xffffec, .length = 24 }, // 144
    .{ .bits = 0xffffed, .length = 24 }, // 145
    .{ .bits = 0x3fffd7, .length = 22 }, // 146
    .{ .bits = 0x7fffe0, .length = 23 }, // 147
    .{ .bits = 0xffffee, .length = 24 }, // 148
    .{ .bits = 0x7fffe1, .length = 23 }, // 149
    .{ .bits = 0x7fffe2, .length = 23 }, // 150
    .{ .bits = 0x7fffe3, .length = 23 }, // 151
    .{ .bits = 0x7fffe4, .length = 23 }, // 152
    .{ .bits = 0x1fffdc, .length = 21 }, // 153
    .{ .bits = 0x3fffd8, .length = 22 }, // 154
    .{ .bits = 0x7fffe5, .length = 23 }, // 155
    .{ .bits = 0x3fffd9, .length = 22 }, // 156
    .{ .bits = 0x7fffe6, .length = 23 }, // 157
    .{ .bits = 0x7fffe7, .length = 23 }, // 158
    .{ .bits = 0xffffef, .length = 24 }, // 159
    .{ .bits = 0x3fffda, .length = 22 }, // 160
    .{ .bits = 0x1fffdd, .length = 21 }, // 161
    .{ .bits = 0xfffe9, .length = 20 }, // 162
    .{ .bits = 0x3fffdb, .length = 22 }, // 163
    .{ .bits = 0x3fffdc, .length = 22 }, // 164
    .{ .bits = 0x7fffe8, .length = 23 }, // 165
    .{ .bits = 0x7fffe9, .length = 23 }, // 166
    .{ .bits = 0x1fffde, .length = 21 }, // 167
    .{ .bits = 0x7fffea, .length = 23 }, // 168
    .{ .bits = 0x3fffdd, .length = 22 }, // 169
    .{ .bits = 0x3fffde, .length = 22 }, // 170
    .{ .bits = 0xfffff0, .length = 24 }, // 171
    .{ .bits = 0x1fffdf, .length = 21 }, // 172
    .{ .bits = 0x3fffdf, .length = 22 }, // 173
    .{ .bits = 0x7fffeb, .length = 23 }, // 174
    .{ .bits = 0x7fffec, .length = 23 }, // 175
    .{ .bits = 0x1fffe0, .length = 21 }, // 176
    .{ .bits = 0x1fffe1, .length = 21 }, // 177
    .{ .bits = 0x3fffe0, .length = 22 }, // 178
    .{ .bits = 0x1fffe2, .length = 21 }, // 179
    .{ .bits = 0x7fffed, .length = 23 }, // 180
    .{ .bits = 0x3fffe1, .length = 22 }, // 181
    .{ .bits = 0x7fffee, .length = 23 }, // 182
    .{ .bits = 0x7fffef, .length = 23 }, // 183
    .{ .bits = 0xfffea, .length = 20 }, // 184
    .{ .bits = 0x3fffe2, .length = 22 }, // 185
    .{ .bits = 0x3fffe3, .length = 22 }, // 186
    .{ .bits = 0x3fffe4, .length = 22 }, // 187
    .{ .bits = 0x7ffff0, .length = 23 }, // 188
    .{ .bits = 0x3fffe5, .length = 22 }, // 189
    .{ .bits = 0x3fffe6, .length = 22 }, // 190
    .{ .bits = 0x7ffff1, .length = 23 }, // 191
    .{ .bits = 0x3ffffe0, .length = 26 }, // 192
    .{ .bits = 0x3ffffe1, .length = 26 }, // 193
    .{ .bits = 0xfffeb, .length = 20 }, // 194
    .{ .bits = 0x7fff1, .length = 19 }, // 195
    .{ .bits = 0x3fffe7, .length = 22 }, // 196
    .{ .bits = 0x7ffff2, .length = 23 }, // 197
    .{ .bits = 0x3fffe8, .length = 22 }, // 198
    .{ .bits = 0x1ffffec, .length = 25 }, // 199
    .{ .bits = 0x3ffffe2, .length = 26 }, // 200
    .{ .bits = 0x3ffffe3, .length = 26 }, // 201
    .{ .bits = 0x3ffffe4, .length = 26 }, // 202
    .{ .bits = 0x7ffffde, .length = 27 }, // 203
    .{ .bits = 0x7ffffdf, .length = 27 }, // 204
    .{ .bits = 0x3ffffe5, .length = 26 }, // 205
    .{ .bits = 0xfffff1, .length = 24 }, // 206
    .{ .bits = 0x1ffffed, .length = 25 }, // 207
    .{ .bits = 0x7fff2, .length = 19 }, // 208
    .{ .bits = 0x1fffe3, .length = 21 }, // 209
    .{ .bits = 0x3ffffe6, .length = 26 }, // 210
    .{ .bits = 0x7ffffe0, .length = 27 }, // 211
    .{ .bits = 0x7ffffe1, .length = 27 }, // 212
    .{ .bits = 0x3ffffe7, .length = 26 }, // 213
    .{ .bits = 0x7ffffe2, .length = 27 }, // 214
    .{ .bits = 0xfffff2, .length = 24 }, // 215
    .{ .bits = 0x1fffe4, .length = 21 }, // 216
    .{ .bits = 0x1fffe5, .length = 21 }, // 217
    .{ .bits = 0x3ffffe8, .length = 26 }, // 218
    .{ .bits = 0x3ffffe9, .length = 26 }, // 219
    .{ .bits = 0xffffffd, .length = 28 }, // 220
    .{ .bits = 0x7ffffe3, .length = 27 }, // 221
    .{ .bits = 0x7ffffe4, .length = 27 }, // 222
    .{ .bits = 0x7ffffe5, .length = 27 }, // 223
    .{ .bits = 0xfffec, .length = 20 }, // 224
    .{ .bits = 0xfffff3, .length = 24 }, // 225
    .{ .bits = 0xfffed, .length = 20 }, // 226
    .{ .bits = 0x1fffe6, .length = 21 }, // 227
    .{ .bits = 0x3fffe9, .length = 22 }, // 228
    .{ .bits = 0x1fffe7, .length = 21 }, // 229
    .{ .bits = 0x1fffe8, .length = 21 }, // 230
    .{ .bits = 0x7ffff3, .length = 23 }, // 231
    .{ .bits = 0x3fffea, .length = 22 }, // 232
    .{ .bits = 0x3fffeb, .length = 22 }, // 233
    .{ .bits = 0x1ffffee, .length = 25 }, // 234
    .{ .bits = 0x1ffffef, .length = 25 }, // 235
    .{ .bits = 0xfffff4, .length = 24 }, // 236
    .{ .bits = 0xfffff5, .length = 24 }, // 237
    .{ .bits = 0x3ffffea, .length = 26 }, // 238
    .{ .bits = 0x7ffff4, .length = 23 }, // 239
    .{ .bits = 0x3ffffeb, .length = 26 }, // 240
    .{ .bits = 0x7ffffe6, .length = 27 }, // 241
    .{ .bits = 0x3ffffec, .length = 26 }, // 242
    .{ .bits = 0x3ffffed, .length = 26 }, // 243
    .{ .bits = 0x7ffffe7, .length = 27 }, // 244
    .{ .bits = 0x7ffffe8, .length = 27 }, // 245
    .{ .bits = 0x7ffffe9, .length = 27 }, // 246
    .{ .bits = 0x7ffffea, .length = 27 }, // 247
    .{ .bits = 0x7ffffeb, .length = 27 }, // 248
    .{ .bits = 0xffffffe, .length = 28 }, // 249
    .{ .bits = 0x7ffffec, .length = 27 }, // 250
    .{ .bits = 0x7ffffed, .length = 27 }, // 251
    .{ .bits = 0x7ffffee, .length = 27 }, // 252
    .{ .bits = 0x7ffffef, .length = 27 }, // 253
    .{ .bits = 0x7fffff0, .length = 27 }, // 254
    .{ .bits = 0x3ffffee, .length = 26 }, // 255 (EOS symbol)
};

/// Encode data using Huffman coding
pub fn encode(output: []u8, input: []const u8) !usize {
    var bit_buffer: u64 = 0;
    var bits_in_buffer: u6 = 0;
    var out_pos: usize = 0;

    for (input) |byte| {
        const code = HUFFMAN_TABLE[byte];

        // Add code bits to buffer
        bit_buffer = (bit_buffer << @intCast(code.length)) | code.bits;
        bits_in_buffer += code.length;

        // Write complete bytes to output
        while (bits_in_buffer >= 8) {
            bits_in_buffer -= 8;
            if (out_pos >= output.len) return Error.BufferTooSmall;
            output[out_pos] = @intCast((bit_buffer >> @intCast(bits_in_buffer)) & 0xFF);
            out_pos += 1;
        }
    }

    // Write remaining bits with padding (all 1s per RFC 7541)
    if (bits_in_buffer > 0) {
        if (out_pos >= output.len) return Error.BufferTooSmall;
        const padding = 8 - bits_in_buffer;
        const padding_mask: u8 = (@as(u8, 1) << @intCast(padding)) - 1;
        output[out_pos] = @intCast(((bit_buffer << @intCast(padding)) | padding_mask) & 0xFF);
        out_pos += 1;
    }

    return out_pos;
}

/// Decode tree node for Huffman decoding
pub const DecodeNode = struct {
    symbol: ?u8 = null, // If not null, this is a leaf node with this symbol
    left: ?usize = null, // Index to left child (bit = 0)
    right: ?usize = null, // Index to right child (bit = 1)
};

/// Build decoding tree from Huffman table
pub fn buildDecodeTree(allocator: std.mem.Allocator) ![]DecodeNode {
    // Allocate enough nodes for a complete tree
    // Max depth is 30, so max nodes is 2^31 - 1, but we'll use a more reasonable estimate
    var nodes = try allocator.alloc(DecodeNode, 512);
    @memset(nodes, DecodeNode{});

    var next_node: usize = 1; // Node 0 is root

    // Insert each symbol into the tree
    for (HUFFMAN_TABLE, 0..) |code, symbol| {
        var node_idx: usize = 0; // Start at root
        var bit_idx: u5 = 0;

        while (bit_idx < code.length) : (bit_idx += 1) {
            const bits_remaining = code.length - bit_idx - 1;
            const bit = (code.bits >> @intCast(bits_remaining)) & 1;

            if (bit_idx == code.length - 1) {
                // Leaf node - store symbol
                if (bit == 0) {
                    if (next_node >= nodes.len) {
                        const old_len = nodes.len;
                        nodes = try allocator.realloc(nodes, nodes.len * 2);
                        @memset(nodes[old_len..], DecodeNode{});
                    }
                    nodes[node_idx].left = next_node;
                    nodes[next_node].symbol = @intCast(symbol);
                    next_node += 1;
                } else {
                    if (next_node >= nodes.len) {
                        const old_len = nodes.len;
                        nodes = try allocator.realloc(nodes, nodes.len * 2);
                        @memset(nodes[old_len..], DecodeNode{});
                    }
                    nodes[node_idx].right = next_node;
                    nodes[next_node].symbol = @intCast(symbol);
                    next_node += 1;
                }
                break;
            } else {
                // Internal node - traverse or create
                const next = if (bit == 0) nodes[node_idx].left else nodes[node_idx].right;

                if (next) |n| {
                    node_idx = n;
                } else {
                    if (next_node >= nodes.len) {
                        const old_len = nodes.len;
                        nodes = try allocator.realloc(nodes, nodes.len * 2);
                        @memset(nodes[old_len..], DecodeNode{});
                    }
                    if (bit == 0) {
                        nodes[node_idx].left = next_node;
                    } else {
                        nodes[node_idx].right = next_node;
                    }
                    node_idx = next_node;
                    next_node += 1;
                }
            }
        }
    }

    return try allocator.realloc(nodes, next_node);
}

/// Decode Huffman-encoded data
pub fn decode(output: []u8, input: []const u8, tree: []const DecodeNode) !usize {
    var out_pos: usize = 0;
    var node_idx: usize = 0; // Start at root

    // Bits consumed since we were last at the root. Per RFC 7541 §5.2 the only
    // valid way for the stream to end mid-code is trailing padding, which must
    // be fewer than 8 bits and all 1s (the MSBs of the EOS code).
    var bits_since_root: usize = 0;

    for (input) |byte| {
        var bit_idx: u4 = 0;
        while (bit_idx < 8) : (bit_idx += 1) {
            const bit = (byte >> @intCast(7 - bit_idx)) & 1;

            // Traverse tree
            node_idx = if (bit == 0)
                tree[node_idx].left orelse return Error.InvalidHuffmanCode
            else
                tree[node_idx].right orelse return Error.InvalidHuffmanCode;
            bits_since_root += 1;

            // Check if we reached a leaf
            if (tree[node_idx].symbol) |symbol| {
                if (out_pos >= output.len) return Error.BufferTooSmall;
                output[out_pos] = symbol;
                out_pos += 1;
                node_idx = 0; // Reset to root
                bits_since_root = 0;
            }
        }
    }

    // At end of input we must be at the root (a fully consumed code) or in the
    // middle of a code that is purely padding. Padding is at most 7 bits and
    // consists entirely of 1s, so the partial path from the root must have
    // followed only right (bit = 1) edges.
    if (node_idx != 0) {
        if (bits_since_root >= 8) return Error.InvalidHuffmanCode;

        // Walk from the root along right edges for bits_since_root steps and
        // confirm we arrive at the node we are stuck on: this proves every
        // padding bit was a 1.
        var check_idx: usize = 0;
        var i: usize = 0;
        while (i < bits_since_root) : (i += 1) {
            check_idx = tree[check_idx].right orelse return Error.InvalidPadding;
        }
        if (check_idx != node_idx) return Error.InvalidPadding;
    }

    return out_pos;
}

/// Calculate encoded size without actually encoding
pub fn encodedSize(input: []const u8) usize {
    var bits: usize = 0;
    for (input) |byte| {
        bits += HUFFMAN_TABLE[byte].length;
    }
    // Round up to nearest byte
    return (bits + 7) / 8;
}

test "huffman encode/decode simple" {
    const allocator = std.testing.allocator;

    const input = "www.example.com";
    var encoded: [256]u8 = undefined;
    var decoded: [256]u8 = undefined;

    const enc_len = try encode(&encoded, input);

    const tree = try buildDecodeTree(allocator);
    defer allocator.free(tree);

    const dec_len = try decode(&decoded, encoded[0..enc_len], tree);

    try std.testing.expectEqualStrings(input, decoded[0..dec_len]);

    // Huffman should compress common text
    try std.testing.expect(enc_len < input.len);
}

test "huffman encode all bytes" {
    const allocator = std.testing.allocator;

    // Test all possible bytes
    var input: [256]u8 = undefined;
    for (&input, 0..) |*byte, i| {
        byte.* = @intCast(i);
    }

    var encoded: [1024]u8 = undefined;
    var decoded: [256]u8 = undefined;

    const enc_len = try encode(&encoded, &input);

    const tree = try buildDecodeTree(allocator);
    defer allocator.free(tree);

    const dec_len = try decode(&decoded, encoded[0..enc_len], tree);

    try std.testing.expectEqualSlices(u8, &input, decoded[0..dec_len]);
}

test "huffman encode rejects undersized output buffer" {
    // "www.example.com" compresses to several bytes; a 1-byte sink cannot hold
    // it, so the encoder must report BufferTooSmall rather than write OOB.
    var tiny: [1]u8 = undefined;
    try std.testing.expectError(Error.BufferTooSmall, encode(&tiny, "www.example.com"));
}

test "huffman decode rejects invalid padding" {
    const allocator = std.testing.allocator;

    const tree = try buildDecodeTree(allocator);
    defer allocator.free(tree);

    // 0x00 decodes symbol '0' (5 zero bits) then leaves 3 trailing zero bits.
    // Valid padding must be all 1s, so a zero-bit remainder is rejected.
    var out: [16]u8 = undefined;
    try std.testing.expectError(Error.InvalidPadding, decode(&out, &[_]u8{0x00}, tree));
}

test "huffman decode rejects undersized output buffer" {
    const allocator = std.testing.allocator;

    const tree = try buildDecodeTree(allocator);
    defer allocator.free(tree);

    var encoded: [64]u8 = undefined;
    const enc_len = try encode(&encoded, "example");

    // The decoded form needs 7 bytes; a 2-byte sink must trip BufferTooSmall
    // instead of writing past the output slice.
    var out: [2]u8 = undefined;
    try std.testing.expectError(Error.BufferTooSmall, decode(&out, encoded[0..enc_len], tree));
}
