package imtoa

import c "core:c/libc"
import pq "core:container/priority_queue"
import "core:fmt"
import "core:image"
import "core:image/png"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

PROG_NAME :: #config(PROG_NAME, "")
PROG_VERSION :: #config(PROG_VERSION, "")

AIM_MAGIC_NUMBER :: "\x4e\x4f\x54\x55\x52\x4d\x4f\x4d"

//DEFAULT_CHAR_GRADIENT :: " .,:=nml?JUOM&W#"
//DEFAULT_CHAR_GRADIENT :: " .-:iuom?lO0WM%#"
// TODO: variable gradient steps
DEFAULT_CHAR_GRADIENT :: " .-:iuom?lO0WM%#"

main :: proc() {
  if !start() do os.exit(1)
}

start :: proc() -> (ok: bool) {
  prog := Prog{}
  prog_init(&prog)
  defer prog_deinit(&prog)

  if !parse_args(&prog) {
    usage()
    return false
  }

  load_image(&prog) or_return
  read_image(&prog)
  write_txt(&prog) or_return

  return true
}

usage :: proc() {
  fmt.eprintfln(
    "Usage: %v <image.png> [-g <char_gradient>] [-s <hscale:vscale> | -S <WxH>] [-o <output_path>] [--plain]",
    PROG_NAME,
  )
}

parse_args :: proc(prog: ^Prog) -> (ok: bool) {
  next_args :: proc(args: ^[]string, parsed: ^int = nil) -> string {
    args := args
    if len(args^) <= 0 do return ""
    if parsed != nil do parsed^ += 1
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
  case:
    prog.img_path = meta_arg
  }

  for len(args) > 0 {
    arg: string
    arg = next_args(&args)

    switch arg {
    case "-g":
      prog.char_gradient = next_args(&args, &parsed)

    case "-s":
      scale_str: string
      scale_str = next_args(&args, &parsed)
      scale := strings.split(scale_str, ":", context.temp_allocator)
      if len(scale) != 2 do return false
      prog.scale = {strconv.parse_f32(scale[0]) or_return, strconv.parse_f32(scale[1]) or_return}

    case "-S":
      size_str: string
      size_str = next_args(&args, &parsed)
      size := strings.split(size_str, "x", context.temp_allocator)
      if len(size) != 2 do return false
      prog.scaled_size = {
        strconv.parse_uint(size[0]) or_return,
        strconv.parse_uint(size[1]) or_return,
      }

    case "-o":
      prog.output_path = next_args(&args, &parsed)

    case "--plain":
      prog.plain = true

    case:
      parsed -= 1
    }

    if args != nil {
      parsed += 1
    }
  }

  if len(os.args) != parsed do return false

  if len(prog.char_gradient) != 16 {
    fmt.eprintln("Char gradient's length is not 16 characters")
    return false
  }
  // how can you come up with >255 unique ASCII chars anyway?
  // but char_gradient could contain duplicate chars
  if len(prog.char_gradient) > 255 {
    fmt.eprintln("The gradient is too detailed!")
    return false
  }

  return true
}

Pixel :: distinct [4]byte
Pixels :: distinct []Pixel

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
}

prog_init :: proc(using self: ^Prog) {
  char_gradient = DEFAULT_CHAR_GRADIENT
  scale = {1, 1}
}

prog_deinit :: proc(using self: ^Prog) {
  png.destroy(img)
  delete(pixels)
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

read_image :: proc(using prog: ^Prog) {
  scaled_img_buf := scale_image(img, scaled_size, context.temp_allocator)

  for &pixel, i in pixels {
    for j in 0 ..< img.channels {
      pixel[j] = scaled_img_buf[i * img.channels + j]
    }
  }
}

// https://web.archive.org/web/20170809062128/http://willperone.net/Code/codescaling.php
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

write_txt :: proc(using prog: ^Prog) -> (ok: bool) {
  file_path :=
    output_path != "" \
    ? output_path \
    : strings.concatenate(
      {filepath.stem(img_path), !plain ? ".aim" : ".txt"},
      context.temp_allocator,
    )

  text := make([]byte, scaled_size.x * scaled_size.y)
  for &char, i in text {
    char = pixel_to_ascii(pixels[i], char_gradient)
  }
  defer delete(text)

  // NOTE: using libc is faster than os.open for some reason
  file := c.fopen(strings.clone_to_cstring(file_path, context.temp_allocator), "w+")
  if file == nil {
    fmt.eprintln("Failed to open %s", file_path)
    return false
  }
  defer c.fclose(file)

  if plain do write_plain_txt(prog, file, text) or_return
  else do write_compressed_txt(prog, file, text) or_return

  return true
}

write_compressed_txt :: proc(using prog: ^Prog, file: ^c.FILE, text: []byte) -> (ok: bool) {
  arena: virtual.Arena
  assert(virtual.arena_init_growing(&arena) == nil)
  defer virtual.arena_destroy(&arena)
  arena_alloc := virtual.arena_allocator(&arena)

  context.allocator = arena_alloc

  char_freq := make(map[byte]uint, len(char_gradient))
  for char in char_gradient {
    map_insert(&char_freq, u8(char), 0)
  }
  for &char in text {
    char_freq[char] += 1
  }

  huffman_tree := huffman_encode(char_freq)
  huffman_codes := make(map[byte]string)
  huffman_extract_code(huffman_tree, &huffman_codes)

  // magic number
  c.fprintf(file, strings.clone_to_cstring(AIM_MAGIC_NUMBER, context.temp_allocator))
  // stride, [ascii_digit:1]... [0x00]
  c.fprintf(file, "%zu", scaled_size.x)
  c.fprintf(file, "%c", 0)
  // number of unique chars (8-bit integer), [int:1]
  assert(len(char_gradient) < 256)
  c.fprintf(file, "%c", byte(len(char_gradient)))
  // lookup table, [char:1] [huffman_code_len:1] [encoded_value:len(v)]
  for k, &v in huffman_codes {
    // print the huffman codes for debugging
    //fmt.printfln("'%c': %v", k, v)

    if len(v) >= 256 {
      fmt.eprintln("The gradient is too detailed!")
      return false
    }
    bytes := parse_binary(v, context.temp_allocator)
    assert(bytes != nil)
    c.fprintf(file, "%c", k)
    c.fprintf(file, "%c", byte(len(v)))
    for &b in bytes {
      c.fprintf(file, "%c", b)
    }
  }
  // actual data, [huffman_codes:variable]
  encoded_text := make([dynamic]byte, 0, len(text))
  for &char in text {
    huffman_code := utf8.string_to_runes(huffman_codes[char])
    for &rune in huffman_code {
      encoded_rune, _ := utf8.encode_rune(rune)
      append(&encoded_text, encoded_rune[0])
    }
  }
  whole_bytes := parse_binary(strings.clone_from_bytes(encoded_text[:], context.temp_allocator))
  for &byte in whole_bytes {
    c.fprintf(file, "%c", byte)
  }

  return true
}

write_plain_txt :: proc(using prog: ^Prog, file: ^c.FILE, text: []byte) -> (ok: bool) {
  for y in 0 ..< scaled_size.y {
    for x in 0 ..< scaled_size.x {
      c.fprintf(file, "%c", text[x + scaled_size.x * y])
    }
    c.fprintf(file, "\n")
  }
  return true
}

// big-endian
parse_binary :: proc(str: string, allocator := context.allocator) -> []byte {
  acc := make([]byte, (len(str) + 8 - 1) / 8, allocator)
  for c, i in str {
    switch c {
    case '0':
      acc[i / 8] |= byte(0x00) >> (uint(i) % 8)
    case '1':
      acc[i / 8] |= byte(0x80) >> (uint(i) % 8)
    case 0x00:
      continue
    case:
      return nil
    }
  }
  return acc
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

huffman_extract_code :: proc(
  root: ^HuffmanNode,
  output: ^map[byte]string,
  allocator := context.allocator,
  trail: string = "",
) {
  if root == nil do return
  if root.data != 0 {
    output[root.data] = fmt.aprint(trail, allocator = allocator)
  }
  left_str := fmt.aprint(trail, "0", sep = "", allocator = allocator)
  right_str := fmt.aprint(trail, "1", sep = "", allocator = allocator)
  defer {
    delete(left_str)
    delete(right_str)
  }
  huffman_extract_code(root.left, output, allocator, left_str)
  huffman_extract_code(root.right, output, allocator, right_str)
}

