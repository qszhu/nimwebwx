import std/[
  json,
  pegs,
  strutils,
]



type
  WxContact* = ref object
    userName*: string
    nickName*: string
    memberCount*: int
    raw*: JsonNode

proc newWxContact*(jso: JsonNode): WxContact =
  result.new
  result.userName = jso["UserName"].getStr
  result.nickName = jso["NickName"].getStr
  result.memberCount = jso{"MemberCount"}.getInt
  result.raw = jso

proc isGroup*(self: WxContact): bool {.inline.} =
  self.userName.startsWith("@@")



type
  WxMessage* = ref object
    msgType*: int
    fromUserName*: string
    toUserName*: string
    content*: string
    raw*: JsonNode

proc newWxMessage*(jso: JsonNode): WxMessage =
  result.new
  result.raw = jso
  result.msgType = jso["MsgType"].getInt
  result.content = jso["Content"].getStr
  result.fromUserName = jso["FromUserName"].getStr
  result.toUserName = jso["ToUserName"].getStr

proc parseContent*(self: WxMessage): (string, string) =
  let p = """ {'@' [0-9a-f]+} ':' {.+} """.peg
  if self.content =~ p:
    return (matches[0], matches[1].replace("<br/>", "\n").strip)
