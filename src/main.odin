package main

import "core:bytes"
import c "core:c/libc"
import "core:fmt"
import "core:image/png"
import "core:io"
import "core:os"
import "core:path/filepath"
import "core:strings"

PROG_NAME :: #config(PROG_NAME, "")
PROG_VERSION :: #config(PROG_VERSION, "")

DEFAULT_CHAR_GRADIENT :: " .,-+=icowmICMW#"

main :: proc() {
  if len(os.args) < 2 {
    fmt.eprintfln("Usage: %v <image> [char_gradient]", PROG_NAME)
    os.exit(1)
  }

  prog := Prog{}
  if !prog_init(&prog) do os.exit(1)
  defer prog_deinit(&prog)

  read_image(&prog)

  if !write_txt(&prog) do os.exit(1)
}

Pixel :: []byte
Pixels :: distinct []Pixel

Prog :: struct {
  img:           ^png.Image,
  img_path:      string,
  pixels:        Pixels,
  char_gradient: string,
}

prog_init :: proc(using prog: ^Prog) -> (ok: bool) {
  img_path = os.args[1]
  if len(os.args) >= 3 {
    char_gradient = os.args[2]
    if len(char_gradient) != 16 {
      fmt.eprintln("Char gradient's length is not 16 characters")
      return false
    }
  } else {
    char_gradient = DEFAULT_CHAR_GRADIENT
  }

  err: png.Error
  img, err = png.load_from_file(img_path)
  if err != nil {
    fmt.eprintfln("Failed to load %v: %v", img_path, err)
    os.exit(1)
  }

  pixels = make(Pixels, img.width * img.height)
  for &pixel in pixels {
    pixel = make(Pixel, img.channels)
  }

  return true
}

prog_deinit :: proc(using self: ^Prog) {
  png.destroy(img)
  for &p in pixels do delete(p)
  delete(pixels)
}

read_image :: proc(using prog: ^Prog) {
  err: io.Error
  for err == nil {
    pixel := make(Pixel, img.channels)
    defer delete(pixel)

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

get_cmax :: proc(pixel: Pixel) -> byte {
  cmax: byte
  for i in 0 ..< 3 {
    cmax = max(cmax, pixel[i])
  }
  return cmax
}

pixel_to_ascii :: proc(pixel: Pixel, char_gradient: string) -> u8 {
  return char_gradient[int(get_cmax(pixel) / 0x10)]
}

write_txt :: proc(using prog: ^Prog) -> (ok: bool) {
  defer free_all(context.temp_allocator)
  file_path := fmt.aprint(
    filepath.stem(img_path),
    ".txt",
    sep = "",
    allocator = context.temp_allocator,
  )

  file := c.fopen(strings.clone_to_cstring(file_path, context.temp_allocator), "w+")
  if file == nil {
    fmt.eprintln("Failed to open %s", file_path)
    return false
  }
  defer c.fclose(file)

  for y in 0 ..< img.height {
    for x in 0 ..< img.width {
      c.fprintf(file, "%c", pixel_to_ascii(pixels[x + img.width * y], char_gradient))
    }
    c.fprintf(file, "\n")
  }

  return true
}

