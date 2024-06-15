package imtoa

import "base:intrinsics"
import c "core:c/libc"
import pq "core:container/priority_queue"
import "core:fmt"
import "core:image"
import "core:image/png"
import "core:math/bits"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:sort"
import "core:strconv"
import "core:strings"

PROG_NAME :: #config(PROG_NAME, "")
PROG_VERSION :: #config(PROG_VERSION, "")

AIM_MAGIC_NUMBER :: "\x4e\x4f\x54\x55\x52\x4d\x4f\x4d"

//DEFAULT_CHAR_GRADIENT :: " .,:=nml?JUOM&W#"
//DEFAULT_CHAR_GRADIENT :: " .-:iuom?lO0WM%#"
// TODO: variable gradient steps
// TODO: check if gradient only contains ASCII chars (https://pkg.odin-lang.org/core/strings/#ascii_set_contains)
DEFAULT_CHAR_GRADIENT :: " .-:iuom?lO0WM%#"

Pixel :: [4]byte
Pixels :: []Pixel
Bits :: []bool

Prog :: struct {
    img:           ^png.Image,
    img_path:      string,
    pixels:        Pixels,
    scaled_size:   [2]uint,
    /**/
    char_gradient: string,
    scale:         [2]f32,
    output_path:   string,
    plain:         bool,
    view:          bool, // view a .aim file instead of converting from .png image
    editor:        string,
    debug:         bool,
}

prog_init :: proc(using self: ^Prog) {
    char_gradient = DEFAULT_CHAR_GRADIENT
    scale = {1, 1}
}

prog_destroy :: proc(using self: ^Prog) {
    png.destroy(img)
    delete(pixels)
}

main :: proc() {
    defer free_all(context.temp_allocator)
    when ODIN_DEBUG {
        mem_track: mem.Tracking_Allocator
        mem.tracking_allocator_init(&mem_track, context.allocator)
        context.allocator = mem.tracking_allocator(&mem_track)
        defer {
            if len(mem_track.allocation_map) > 0 {
                fmt.eprintfln("### %v unfreed allocations ###", len(mem_track.allocation_map))
                for _, v in mem_track.allocation_map {
                    fmt.eprintfln("    %v bytes in %v", v.size, v.location)
                }
            }
            if len(mem_track.bad_free_array) > 0 {
                fmt.eprintfln("### %v bad frees ###", len(mem_track.bad_free_array))
                for x in mem_track.bad_free_array {
                    fmt.eprintfln("    %p in %v", x.memory, x.location)
                }
            }
            mem.tracking_allocator_destroy(&mem_track)
        }
    } else {
        // suppress vet (unused import "core:mem")
        _ = mem.Byte
    }
    if !start() {
        os.exit(1)
    }
}

start :: proc() -> (ok: bool) {
    prog := Prog{}
    prog_init(&prog)
    defer prog_destroy(&prog)

    if !parse_args(&prog) {
        usage()
        return false
    }

    if !prog.view {
        load_image(&prog) or_return
        read_image(prog)
        write_txt(prog) or_return
    } else {
        err := view_aim(prog)
        switch err {
        case .None:
            return true
        case .Cannot_Read_File:
            fmt.eprintfln("Failed to read %s", prog.img_path)
        case .Unexpected_EOF:
            fmt.eprintfln("Encountered unexpected EOF when reading %s", prog.img_path)
        case .Invalid_File:
            fmt.eprintfln("%s is not a valid .aim file", prog.img_path)
        case .Cannot_View:
            fmt.eprintfln("Decoded %s but failed to view it", prog.img_path)
        }
        return false
    }

    return true
}

usage :: proc() {
    fmt.eprintfln(
        `Usage: %v <convert <image.png>|view <image.aim>|--help|--version> [options]...
Options (convert):
    -g <char_gradient>      The gradient palette
    -s <hscale:vscale>      The scale to the original resolution
    -S <WxH>                The resolution (overrides -s)
    -o <output_path>        The output path
    --plain                 Convert to plain .txt file
Options (view):
    -o <output_path>        The output path as .txt file
    -e <editor>             The text editor to view the image`,
        PROG_NAME,
    )
}

parse_args :: proc(prog: ^Prog) -> (ok: bool) {
    next_args :: proc(args: ^[]string, parsed: ^int = nil) -> string {
        if len(args^) <= 0 {
            args^ = nil
            return ""
        }
        if parsed != nil {
            parsed^ += 1
        }
        curr := args[0]
        args^ = args[1:]
        return curr
    }

    parsed: int
    args := os.args
    _ = next_args(&args, &parsed)

    meta_arg: string
    meta_arg = next_args(&args, &parsed)
    switch meta_arg {
    case "-h", "--help":
        return false
    case "-v", "--version":
        fmt.printfln("%v v%v", PROG_NAME, PROG_VERSION)
        return false
    case "convert":
        prog.img_path = next_args(&args, &parsed)
    case "view":
        prog.view = true
        prog.img_path = next_args(&args, &parsed)
    case:
        return false
    }
    if args == nil {
        return false
    }

    for len(args) > 0 {
        arg := next_args(&args)

        if !prog.view {
            switch arg {
            case "-g":
                prog.char_gradient = next_args(&args, &parsed)

            case "-s":
                scale_str: string
                scale_str = next_args(&args, &parsed)
                scale := strings.split(scale_str, ":", context.temp_allocator)
                if len(scale) != 2 {
                    return false
                }
                prog.scale = {
                    strconv.parse_f32(scale[0]) or_return,
                    strconv.parse_f32(scale[1]) or_return,
                }

            case "-S":
                size_str: string
                size_str = next_args(&args, &parsed)
                size := strings.split(size_str, "x", context.temp_allocator)
                if len(size) != 2 {
                    return false
                }
                prog.scaled_size = {
                    strconv.parse_uint(size[0]) or_return,
                    strconv.parse_uint(size[1]) or_return,
                }

            case "-o":
                prog.output_path = next_args(&args, &parsed)

            case "--plain":
                prog.plain = true

            case "--debug":
                when ODIN_DEBUG {
                    prog.debug = true
                } else {
                    fallthrough
                }

            case:
                parsed -= 1
            }
        } else {
            switch arg {
            case "-e":
                prog.editor = next_args(&args, &parsed)

            case "-o":
                prog.output_path = next_args(&args, &parsed)

            case "--debug":
                when ODIN_DEBUG {
                    prog.debug = true
                } else {
                    fallthrough
                }

            case:
                parsed -= 1
            }
        }

        if args != nil {
            parsed += 1
        }
    }

    if len(os.args) != parsed {
        return false
    }

    if len(prog.char_gradient) != 16 {
        fmt.eprintln("Char gradient's length is not 16 characters")
        return false
    }
    for char in prog.char_gradient {
        if char == 0 {
            fmt.eprintln("NUL byte is not allowed in char gradient")
            return false
        }
    }
    // how can you come up with >255 unique ASCII chars anyway?
    // but char_gradient could contain duplicate chars
    if len(prog.char_gradient) > 255 {
        fmt.eprintln("The gradient is too detailed!")
        return false
    }

    return true
}

load_image :: proc(using prog: ^Prog) -> (ok: bool) {
    err: png.Error
    img, err = png.load_from_file(img_path)
    if err != nil {
        fmt.eprintfln("Unable to load %s: %v", img_path, err)
        #partial switch v in err {
        case image.General_Image_Error:
            #partial switch v {
            case .Unsupported_Format, .Invalid_Signature:
                fmt.eprintln("Only PNG image is supported for now")
            case .Unable_To_Read_File:
                fmt.eprintln("Unable to read", img_path)
            }
        }
        return false
    }
    if img.channels < 3 || img.channels > 4 {
        fmt.eprintln("Only RGB and RGBA is supported for now")
        return false
    }

    if scaled_size == 0 {
        scaled_size = {uint(f32(img.width) * scale.x), uint(f32(img.height) * scale.y)}
    }
    pixels = make(Pixels, scaled_size.x * scaled_size.y)

    return true
}

read_image :: proc(using prog: Prog) {
    scaled_img_buf: []byte
    if scale == {1, 1} {
        scaled_img_buf = img.pixels.buf[:]
    } else {
        scaled_img_buf = scale_image(img, scaled_size, context.temp_allocator)
    }

    for &pixel, i in pixels {
        for j in 0 ..< img.channels {
            pixel[j] = scaled_img_buf[i * img.channels + j]
        }
    }
}

// https://web.archive.org/web/20170809062128/http://willperone.net/Code/codescaling.php
@(optimization_mode = "speed")
scale_image :: proc(
    input: ^png.Image,
    scaled_size: [2]uint,
    allocator := context.allocator,
) -> []byte {
    assert(input.channels == 3 || input.channels == 4)
    old_size := [2]int{input.width, input.height}
    new_size := [2]int{int(scaled_size.x), int(scaled_size.y)}
    input_buf := input.pixels.buf
    output_buf := make([]byte, new_size.x * new_size.y * input.channels, allocator)

    yd := int((old_size.y / new_size.y) * old_size.x - old_size.x)
    yr := old_size.y % new_size.y
    xd := int(old_size.x / new_size.x)
    xr := old_size.x % new_size.x
    in_off, out_off: int

    for y, ye := new_size.y, 0; y > 0; y -= 1 {
        for x, xe := new_size.x, 0; x > 0; x -= 1 {
            for i in 0 ..< input.channels {
                output_buf[out_off + i] = input_buf[in_off + i]
            }
            out_off += input.channels
            in_off += xd * input.channels
            xe += xr
            if (xe >= new_size.x) {
                xe -= new_size.x
                in_off += input.channels
            }
        }
        in_off += yd * input.channels
        ye += yr
        if (ye >= new_size.y) {
            ye -= new_size.y
            in_off += old_size.x * input.channels
        }
    }

    return output_buf
}

get_lum :: proc(pixel: Pixel) -> byte {
    return byte(0.2126 * f32(pixel.r) + 0.7152 * f32(pixel.g) + 0.0722 * f32(pixel.b))
}

pixel_to_ascii :: proc(pixel: Pixel, char_gradient: string) -> byte {
    return char_gradient[int(get_lum(pixel) / 0x10)]
}

write_txt :: proc(using prog: Prog) -> (ok: bool) {
    file_path :=
        output_path != "" \
        ? output_path \
        : strings.concatenate(
            {filepath.stem(img_path), (!plain ? ".aim" : ".txt")},
            context.temp_allocator,
        )

    // NOTE: using libc is faster than os.open for some reason
    file := c.fopen(to_cstring(file_path), "w")
    if file == nil {
        fmt.eprintln("Failed to open %s", file_path)
        return false
    }
    defer c.fclose(file)

    if plain {
        write_plain_txt(prog, file) or_return
    } else {
        write_compressed_txt(prog, file) or_return
    }

    return true
}

write_compressed_txt :: proc(using prog: Prog, file: ^c.FILE) -> (ok: bool) {
    arena: virtual.Arena
    assert(virtual.arena_init_growing(&arena) == nil)
    defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena)

    // compress repeated chars to one char with prefix indicating number of repeats
    // the MSB indicates that a byte is an ASCII char if 0 or a repeat count if 1
    // NOTE: each unique repeat count acts has its own encoded value
    // TODO: maybe compress repeating pattern of >1 chars
    text := make([dynamic]byte, 0, scaled_size.x * scaled_size.y)
    repeats: byte = 1
    prev_char: byte
    for i in 0 ..= scaled_size.x * scaled_size.y {
        curr_char: byte
        if i < scaled_size.x * scaled_size.y {
            curr_char = pixel_to_ascii(pixels[i], char_gradient)
            assert(curr_char != 0)
        }
        if repeats < byte(1 << 7 - 1) && curr_char == prev_char {     // 7: remaining bits, 1 bits are used for indication
            repeats += 1
        } else if i >= 1 {
            if repeats > 1 {
                append(&text, repeats | 0b10000000)
            }
            append(&text, prev_char)
            repeats = 1
        }
        prev_char = curr_char
    }

    char_freq := make(map[byte]uint, len(char_gradient))
    for char in char_gradient {
        map_insert(&char_freq, u8(char), 0)
    }
    for &char in text {
        char_freq[char] += 1
    }

    huffman_tree := huffman_encode(char_freq)
    huffman_codes := make(map[byte]Bits)
    huffman_extract_code(huffman_tree, &huffman_codes)

    // magic number (8 bytes)
    c.fprintf(file, to_cstring(AIM_MAGIC_NUMBER))

    // stride (u32le, 4 bytes)
    stride := bits.to_le_u32(u32(scaled_size.x))
    c.fwrite(&stride, 1, 4, file)

    // number of unique chars + repeat counts (u8, 1 byte)
    huffman_code_len := u8(len(huffman_codes))
    c.fwrite(&huffman_code_len, 1, 1, file)

    // lookup table: (k, 1 byte) (huffman_code_len, 1 byte) (huffman_code, <huffman_code_len> bits)
    for k, &v in huffman_codes {
        if debug {
            print_codes(k, v)
        }

        if len(v) >= 256 {
            fmt.eprintln("The gradient is too detailed!")
            return false
        }
        bytes, _ := squeeze_bits(v, context.temp_allocator)
        assert(bytes != nil)
        c.fprintf(file, "%c", k)
        c.fprintf(file, "%c", byte(len(v)))
        for &b in bytes {
            c.fprintf(file, "%c", b)
        }
    }

    encoded_bits := make([dynamic]bool, 0, len(text))
    for char in text {
        for bit in huffman_codes[char] {
            append(&encoded_bits, bit)
        }
    }
    whole_bytes, unused_bits := squeeze_bits(encoded_bits[:], context.temp_allocator)

    // number of unused bits at the end of file, (u8, 1 byte)
    c.fprintf(file, "%c", byte(unused_bits))

    // actual data, (huffman_codes)...
    for byte in whole_bytes {
        c.fprintf(file, "%c", byte)
    }

    return true
}

write_plain_txt :: proc(using prog: Prog, file: ^c.FILE) -> (ok: bool) {
    text := make([]byte, scaled_size.x * scaled_size.y)
    for &char, i in text {
        char = pixel_to_ascii(pixels[i], char_gradient)
    }
    defer delete(text)

    for y in 0 ..< scaled_size.y {
        for x in 0 ..< scaled_size.x {
            c.fprintf(file, "%c", text[x + scaled_size.x * y])
        }
        c.fprintf(file, "\n")
    }
    return true
}

Aim_Error :: enum u8 {
    None             = 0,
    Cannot_Read_File = 1,
    Invalid_File     = 2,
    Unexpected_EOF   = 3,
    Cannot_View      = 4,
}

Aim_Image :: struct {
    stride:        u32,
    unique_bytes:  u8,
    huffman_codes: map[byte]Bits,
}

aim_image_init :: proc(using self: ^Aim_Image) {
    huffman_codes = make(map[byte]Bits)
}

aim_image_destroy :: proc(using self: ^Aim_Image) {
    delete(huffman_codes)
}

view_aim :: proc(using prog: Prog) -> (err: Aim_Error) {
    arena: virtual.Arena
    assert(virtual.arena_init_growing(&arena) == nil)
    defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena)

    file_data, ok := os.read_entire_file(img_path)
    if !ok {
        return .Cannot_Read_File
    }

    file := file_data

    signature := consume_file(&file, len(AIM_MAGIC_NUMBER)) or_return
    if strings.clone_from_bytes(signature, context.temp_allocator) != AIM_MAGIC_NUMBER {
        return .Invalid_File
    }

    aim_image := Aim_Image{}
    aim_image_init(&aim_image)
    defer aim_image_destroy(&aim_image)

    aim_image.stride = bits.from_le_u32(consume_file_reinterpret(&file, u32) or_return)
    aim_image.unique_bytes = consume_file_reinterpret(&file, u8) or_return

    for _ in 0 ..< aim_image.unique_bytes {
        key := consume_file_reinterpret(&file, byte) or_return
        length_bits := consume_file_reinterpret(&file, byte) or_return
        length_bytes := (length_bits + 8 - 1) / 8
        value := consume_file(&file, uint(length_bytes)) or_return
        value_bits := make(Bits, length_bits, context.temp_allocator)
        for &bit, i in value_bits {
            byte := value[i / 8]
            bit = bool(byte & (0b10000000 >> uint(i % 8)))
        }
        aim_image.huffman_codes[key] = value_bits
        if debug {
            print_codes(key, aim_image.huffman_codes[key])
        }
    }

    if aim_image.stride <= 0 ||
       aim_image.unique_bytes <= 0 ||
       byte(len(aim_image.huffman_codes)) != aim_image.unique_bytes {
        return .Invalid_File
    }

    unused_bits := consume_file_reinterpret(&file, u8) or_return
    data_bytes := consume_file(&file, 0) or_return
    data_bits := unsqueeze_bits(data_bytes, uint(unused_bits))

    // phase 1: huffman decoding
    decoded_data := huffman_decode(aim_image.huffman_codes, data_bits)

    file_path :=
        output_path != "" \
        ? output_path \
        : strings.concatenate({filepath.stem(img_path), ".txt"}, context.temp_allocator)

    output_file := c.fopen(to_cstring(file_path), "w")
    if output_file == nil {
        fmt.eprintln("Failed to open %s", file_path)
        return .Cannot_View
    }
    defer c.fclose(output_file)

    // phase 2: electric boogaloo
    repeats: byte = 1
    written_chars: uint
    text_sb: strings.Builder
    strings.builder_init(&text_sb)
    for byte in decoded_data {
        if byte & 0b10000000 == 0 {
            for _ in 0 ..< repeats {
                fmt.sbprintf(&text_sb, "%c", byte)
                written_chars += 1
                if written_chars % uint(aim_image.stride) == 0 {
                    fmt.sbprintln(&text_sb)
                }
            }
            repeats = 1
        } else {
            repeats = byte & 0b01111111
        }
    }
    text_cstring := to_cstring(strings.to_string(text_sb))

    if editor == "" || output_path != "" {
        c.fprintf(output_file, "%s", text_cstring)
    }

    // TODO: create a simple pager
    // FIXME: -e is broken
    //        the end part of the temp file is weirldy missing but the file written using the above fprintf is fine
    if editor != "" {
        tmp_file_path_str, _ := strings.replace_all(img_path, "/", "_", context.temp_allocator)
        tmp_file_path := fmt.ctprintf(".#%s#imtoa", tmp_file_path_str)
        tmp_file := c.fopen(tmp_file_path, "w")
        if tmp_file == nil {
            fmt.eprintln("Failed to create temporary file")
            return .Cannot_View
        }
        defer c.fclose(tmp_file)

        defer {
            rm_cmd: cstring
            when ODIN_OS == .Windows {
                rm_cmd = fmt.ctprintf("del %s", tmp_file_path)
            } else when ODIN_OS ==
                .Linux || ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .OpenBSD {
                rm_cmd = fmt.ctprintf("rm %s", tmp_file_path)
            }
            if c.system(rm_cmd) != 0 {
                fmt.eprint("\033[1;33m")
                fmt.eprintfln("[WARNING] Failed to remove temporary file")
                fmt.eprint("\033[0m")
            }
        }

        c.fprintf(tmp_file, "%s", text_cstring)
        if c.system(fmt.ctprintf("%s '%s'", editor, tmp_file_path)) != 0 {
            fmt.eprintfln("Failed to open `%s '%s'`", editor, tmp_file_path)
            return .Cannot_View
        }
    }

    return .None
}

consume_file :: proc(buf: ^[]byte, length: uint) -> (result: []byte, err: Aim_Error) {
    if uint(len(buf^)) - length < 0 {
        return nil, .Unexpected_EOF
    }
    if length == 0 {
        result = buf[:]
        buf^ = nil
    } else {
        result = buf[:length]
        buf^ = buf[length:]
    }
    return result, .None
}

// what the hell is this? https://github.com/odin-lang/Odin/blob/master/core/encoding/endian/endian.odin
consume_file_reinterpret :: proc(buf: ^[]byte, $T: typeid) -> (result: T, err: Aim_Error) {
    return intrinsics.unaligned_load((^T)(raw_data(consume_file(buf, size_of(T)) or_return))),
        .None
}

unsqueeze_bits :: proc(data: []byte, unused_bits: uint, allocator := context.allocator) -> Bits {
    result := make(Bits, uint(len(data) * 8) - unused_bits, allocator)
    outer: for byte, i in data {
        for j in 0 ..< 8 {
            index := j + i * 8
            if index >= len(result) {
                break outer
            }
            result[index] = byte & (0b10000000 >> uint(j)) == 0 ? false : true
        }
    }
    return result
}

// big-endian
squeeze_bits :: proc(
    bits: Bits,
    allocator := context.allocator,
) -> (
    result: []byte,
    remaining: uint,
) {
    length_bytes := (len(bits) + 8 - 1) / 8
    remaining = uint(length_bytes * 8 - len(bits))
    result = make([]byte, length_bytes, allocator)
    for i in 0 ..< len(bits) {
        result[i / 8] |= byte(bits[i] ? 0x80 : 0x00) >> (uint(i) % 8)
    }
    return result, remaining
}

parse_binary_string :: proc(bits: Bits, allocator := context.allocator) -> string {
    sb: strings.Builder
    strings.builder_init(&sb, allocator)
    for i in 0 ..< len(bits) {
        strings.write_rune(&sb, bits[i] ? '1' : '0')
    }
    return strings.to_string(sb)
}

/* HUFFMAN ENCODING STUFF */

HuffmanNode :: struct {
    data:        byte,
    freq:        uint,
    left, right: ^HuffmanNode,
}

huffman_encode :: proc(data: map[byte]uint, allocator := context.allocator) -> ^HuffmanNode {
    left, right, top: ^HuffmanNode

    min_heap: pq.Priority_Queue(^HuffmanNode)
    pq.init(&min_heap, proc(l, r: ^HuffmanNode) -> bool {
            return l.freq < r.freq
        }, pq.default_swap_proc(^HuffmanNode))
    defer pq.destroy(&min_heap)

    for k, v in data {
        node := new(HuffmanNode, allocator)
        node.data = k
        node.freq = v
        pq.push(&min_heap, node)
    }

    for pq.len(min_heap) != 1 {
        left = pq.pop(&min_heap)
        right = pq.pop(&min_heap)
        top = new(HuffmanNode, allocator)
        top^ = {
            data  = 0, // identifier for internal nodes
            freq  = left.freq + right.freq,
            left  = left,
            right = right,
        }
        pq.push(&min_heap, top)
    }

    return pq.pop(&min_heap)
}

@(optimization_mode = "speed")
huffman_extract_code :: proc(
    root: ^HuffmanNode,
    output: ^map[byte]Bits,
    allocator := context.allocator,
    trail: Bits = nil,
    count: uint = 0,
) {
    assert(root != nil)
    if root.data != 0 {
        output[root.data] = new_clone(trail, allocator)^
    } else {
        next_trails := make(Bits, count * 2 + 2)
        left_trail := next_trails[:count + 1]
        right_trail := next_trails[count + 1:]
        copy(left_trail, trail)
        copy(right_trail, trail)
        left_trail[count] = false
        right_trail[count] = true
        huffman_extract_code(root.left, output, allocator, left_trail, count + 1)
        huffman_extract_code(root.right, output, allocator, right_trail, count + 1)
        delete(next_trails)
    }
}

// FIXME: sloooow
@(optimization_mode = "speed")
huffman_decode :: proc(
    codes_map: map[byte]Bits,
    data: Bits,
    allocator := context.allocator,
) -> []byte #no_bounds_check {
    result := make([dynamic]byte, 0, len(data) / 8, allocator)

    min_len: int = max(int)
    for _, v in codes_map {
        min_len = min(len(v), min_len)
    }

    map_entries, _ := slice.map_entries(codes_map)
    defer delete(map_entries)

    map_entry_sort := sort.Interface {
        collection = rawptr(&map_entries),
        len = proc(it: sort.Interface) -> int {
            s := (^[]slice.Map_Entry(byte, Bits))(it.collection)
            return len(s^)
        },
        less = proc(it: sort.Interface, i, j: int) -> bool {
            s := (^[]slice.Map_Entry(byte, Bits))(it.collection)
            return len(s[i].value) < len(s[j].value)
        },
        swap = proc(it: sort.Interface, i, j: int) {
            s := (^[]slice.Map_Entry(byte, Bits))(it.collection)
            s[i], s[j] = s[j], s[i]
        },
    }
    sort.sort(map_entry_sort)

    buf := make([dynamic]bool)
    defer delete(buf)
    for i in 0 ..= len(data) {
        bit: ^bool
        if i < len(data) {
            bit = &data[i]
        }
        if len(buf) < min_len && bit != nil {
            append(&buf, bit^)
        } else {
            for v in map_entries {
                if slice.simple_equal(v.value, buf[:]) {
                    append(&result, v.key)
                    clear(&buf)
                    break
                }
            }
            if bit != nil {
                append(&buf, bit^)
            }
        }
    }

    return result[:]
}

print_codes :: proc(k: byte, v: Bits) {
    if k & 0b10000000 == 0 {
        fmt.printfln("'%c': %v", k, parse_binary_string(v, context.temp_allocator))
    } else {
        fmt.printfln("%v: %v", k & 0b01111111, parse_binary_string(v, context.temp_allocator))
    }
}

to_cstring :: proc(
    s: string,
) -> (
    res: cstring,
    err: mem.Allocator_Error,
) #optional_allocator_error {
    return strings.clone_to_cstring(s, context.temp_allocator)
}

