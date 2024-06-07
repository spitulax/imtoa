package main

import "core:bytes"
import c "core:c/libc"
import "core:fmt"
import "core:image"
import "core:image/png"
import "core:io"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

PROG_NAME :: #config(PROG_NAME, "")
PROG_VERSION :: #config(PROG_VERSION, "")

//DEFAULT_CHAR_GRADIENT :: " .,:=nml?JUOM&W#"
DEFAULT_CHAR_GRADIENT :: " .-:uoil?JO0M&W#"

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
    "Usage: %v <image.png> [-g <char_gradient>] [-s <horz_scale:vert_scale>] [-o <output_path>]",
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
      prog.scale = {
        strconv.parse_uint(scale[0], 10) or_return,
        strconv.parse_uint(scale[1], 10) or_return,
      }

    case "-o":
      prog.output_path, args = next_args(args, &parsed)

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

Pixel :: []byte
Pixels :: distinct []Pixel

Prog :: struct {
  img:           ^png.Image,
  img_path:      string,
  pixels:        Pixels,
  /**/
  char_gradient: string,
  scale:         [2]uint,
  output_path:   string,
}

prog_init :: proc(using prog: ^Prog) {
  char_gradient = DEFAULT_CHAR_GRADIENT
  scale = {1, 1}
}

prog_deinit :: proc(using self: ^Prog) {
  png.destroy(img)
  for &p in pixels do delete(p)
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

  pixels = make(Pixels, img.width * img.height)
  for &pixel in pixels {
    pixel = make(Pixel, img.channels)
  }

  return true
}

read_image :: proc(using prog: ^Prog) {
  defer free_all(context.temp_allocator)

  err: io.Error
  for err == nil {
    pixel := make(Pixel, img.channels, context.temp_allocator)

    for &channel in pixel {
      channel, err = bytes.buffer_read_byte(&img.pixels)
    }
    if img.pixels.off == 0 do break
    copy(pixels[int((img.pixels.off - img.channels) / img.channels)], pixel)
  }
}

print_pixel_hex :: proc(pixel: Pixel) {
  fmt.print("#")
  for i in 0 ..< len(pixel) {
    fmt.printf("%X", pixel[i])
  }
  fmt.println()
}

get_lum :: proc(pixel: Pixel) -> byte {
  return byte(0.2126 * f32(pixel[0]) + 0.7152 * f32(pixel[1]) + 0.0722 * f32(pixel[2]))
}

pixel_to_ascii :: proc(pixel: Pixel, char_gradient: string) -> u8 {
  return char_gradient[int(get_lum(pixel) / 0x10)]
}

write_txt :: proc(using prog: ^Prog) -> (ok: bool) {
  defer free_all(context.temp_allocator)

  file_path :=
    output_path != "" \
    ? output_path \
    : strings.concatenate({filepath.stem(img_path), ".txt"}, context.temp_allocator)

  // NOTE: using libc is faster for some reason
  when true {
    file := c.fopen(strings.clone_to_cstring(file_path, context.temp_allocator), "w+")
    if file == nil {
      fmt.eprintln("Failed to open %s", file_path)
      return false
    }
    defer c.fclose(file)

    for y in 0 ..< img.height {
      for _ in 0 ..< scale.y {
        for x in 0 ..< img.width {
          for _ in 0 ..< scale.x {
            c.fprintf(file, "%c", pixel_to_ascii(pixels[x + img.width * y], char_gradient))
          }
        }
        c.fprintf(file, "\n")
      }
    }
  } else {
    file, err := os.open(file_path, os.O_CREATE | os.O_WRONLY, 0o644)
    if err != os.ERROR_NONE {
      fmt.eprintfln("Failed to open %s", file_path)
      return false
    }
    defer os.close(file)

    for y in 0 ..< img.height {
      for _ in 0 ..< scale.y {
        for x in 0 ..< img.width {
          for _ in 0 ..< scale.x {
            os.write_byte(file, pixel_to_ascii(pixels[x + img.width * y], char_gradient))
          }
        }
        os.write_rune(file, '\n')
      }
    }
  }

  return true
}

