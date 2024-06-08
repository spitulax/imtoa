package main

import c "core:c/libc"
import "core:fmt"
import "core:image"
import "core:image/png"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

PROG_NAME :: #config(PROG_NAME, "")
PROG_VERSION :: #config(PROG_VERSION, "")

AIM_MAGIC_NUMBER :: "\x4e\x4f\x54\x59\x4f\x55\x52\x4d\x4f\x4d"

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
  defer free_all(context.temp_allocator)

  next_args :: proc(args: []string, parsed: ^int = nil) -> (curr: string, next: []string) {
    if len(args) <= 0 do return "", nil
    if parsed != nil do parsed^ += 1
    return args[0], args[1:]
  }

  parsed: int
  args := os.args
  _, args = next_args(args, &parsed)

  meta_arg: string
  meta_arg, args = next_args(args, &parsed)
  switch meta_arg {
  case "-h", "--help":
    return false
  case:
    prog.img_path = meta_arg
  }

  for len(args) > 0 {
    arg: string
    arg, args = next_args(args)

    switch arg {
    case "-g":
      prog.char_gradient, args = next_args(args, &parsed)

    case "-s":
      scale_str: string
      scale_str, args = next_args(args, &parsed)
      scale := strings.split(scale_str, ":", context.temp_allocator)
      if len(scale) != 2 do return false
      prog.scale = {strconv.parse_f32(scale[0]) or_return, strconv.parse_f32(scale[1]) or_return}

    case "-S":
      size_str: string
      size_str, args = next_args(args, &parsed)
      size := strings.split(size_str, "x", context.temp_allocator)
      if len(size) != 2 do return false
      prog.scaled_size = {
        strconv.parse_uint(size[0]) or_return,
        strconv.parse_uint(size[1]) or_return,
      }

    case "-o":
      prog.output_path, args = next_args(args, &parsed)

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
  defer free_all(context.temp_allocator)

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
  defer free_all(context.temp_allocator)

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

  if !plain {
    char_freq := make(map[byte]uint, len(char_gradient))
    defer delete(char_freq)
    for char in char_gradient {
      map_insert(&char_freq, u8(char), 0)
    }
    for &char in text {
      char_freq[char] += 1
    }

    arena: virtual.Arena
    assert(virtual.arena_init_growing(&arena) == nil)
    defer virtual.arena_destroy(&arena)
    huffman_tree := huffman_encode(char_freq, virtual.arena_allocator(&arena))
    _ = huffman_tree

    c.fprintf(file, strings.clone_to_cstring(AIM_MAGIC_NUMBER, context.temp_allocator))
  } else {
    for y in 0 ..< scaled_size.y {
      for x in 0 ..< scaled_size.x {
        c.fprintf(file, "%c", text[x + scaled_size.x * y])
      }
      c.fprintf(file, "\n")
    }
  }

  return true
}

