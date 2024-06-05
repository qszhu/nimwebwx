import std/[
  pegs,
  strutils,
]

from unicode import nil

proc codePointToString(hex: string): string {.inline.} =
  unicode.toUTF8(unicode.Rune(fromHex[uint32](hex)))

proc convertEmoji*(s: string): string =
  let pat = peg""" '<span class="emoji emoji' {(!\" .)+} '"></span>' """
  var matches: array[1, string]
  var p = 0
  while true:
    let (l, r) = s.findBounds(pat, matches, p)
    if l < 0: break
    result &= s[p ..< l]
    result &= matches[0].codePointToString
    p = r + 1



when isMainModule:
  let s = """<span class="emoji emoji1f33f"></span>Phoebe Shen<span class="emoji emoji1f495"></span>"""
  echo s.convertEmoji
