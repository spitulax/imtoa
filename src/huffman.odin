package main

import pq "core:container/priority_queue"
import "core:fmt"

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

huffman_print_code :: proc(root: ^HuffmanNode, str: string = "") {
  if root == nil {
    return
  }
  if root.data != 0 {
    fmt.printfln("'%c': %s", root.data, str)
  }
  str_left := fmt.aprintf("%s0", str)
  str_right := fmt.aprintf("%s1", str)
  defer {
    delete(str_left)
    delete(str_right)
  }
  huffman_print_code(root.left, str_left)
  huffman_print_code(root.right, str_right)
}

