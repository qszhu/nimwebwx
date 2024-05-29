import std/[
  asyncdispatch,
  bitops,
  httpclient,
  json,
  logging,
  options,
  os,
  pegs,
  random,
  sequtils,
  strformat,
  strutils,
  tables,
  times,
  uri,
]

import consts

export asyncdispatch, json
export consts



const LANG = getEnv("LANG",
  "zh_CN")

const USER_AGENT = getEnv("USER_AGENT",
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/111.0.0.0 Safari/537.36")

const LOGIN_HOST = getEnv("LOGIN_HOST",
  "https://login.wx.qq.com")
const JS_LOGIN_URL = getEnv("JS_LOGIN_URL",
  LOGIN_HOST & "/jslogin?appId=wx782c26e4c19acffb&fun=new&lang=zh-CN&redirect_uri=https://wx.qq.com/cgi-bin/mmwebwx-bin/webwxnewloginpage?mod=desktop")
const API_LOGIN_URL = getEnv("API_LOGIN_URL",
  LOGIN_HOST & "/cgi-bin/mmwebwx-bin/login")

const HOST = getEnv("HOST",
  "https://wx2.qq.com") # TODO: get from login redirect url
const API_WEBWX_INIT = getEnv("API_WEBWX_INIT",
  HOST & "/cgi-bin/mmwebwx-bin/webwxinit")
const API_WEBWX_STATUS_NOTIFY = getEnv("API_WEBWX_STATUS_NOTIFY",
  HOST & "/cgi-bin/mmwebwx-bin/webwxstatusnotify")
const API_WEBWX_GET_CONTACT = getEnv("API_WEBWX_GET_CONTACT",
  HOST & "/cgi-bin/mmwebwx-bin/webwxgetcontact")
const API_WEBWX_BATCH_GET_CONTACT = getEnv("API_WEBWX_BATCH_GET_CONTACT",
  HOST & "/cgi-bin/mmwebwx-bin/webwxbatchgetcontact")
const API_WEBWX_SYNC = getEnv("API_WEBWX_SYNC",
  HOST & "/cgi-bin/mmwebwx-bin/webwxsync")
const API_WEBWX_SEND_MSG = getEnv("API_WEBWX_SEND_MSG",
  HOST & "/cgi-bin/mmwebwx-bin/webwxsendmsg")

const PUSH_HOST = getEnv("PUSH_HOST",
  "https://webpush.wx2.qq.com")
const API_SYNC_CHECK = getEnv("API_SYNC_CHECK",
  PUSH_HOST & "/cgi-bin/mmwebwx-bin/synccheck")

type
  LoginProps = object
    skey: string
    sid: string
    uin: string
    passTicket: string
    syncKey: JsonNode
    formatedSyncKey: string

type
  WxClient* = ref object
    cookies: Table[string, string]
    deviceId: string
    props: LoginProps

proc setCookies(self: WxClient, cookies: openArray[(string, string)]) =
  for (k, v) in cookies:
    self.cookies[k] = v

proc getTimestamp(): int64 {.inline.} =
  (getTime().toUnixFloat * 1000).int64

proc getPgv(c = ""): string =
  var t = rand(0x7fffffff'i64)
  if t == 0: t = 0x3fffffff'i64
  t *= getTimestamp() mod 1e10.int
  &"{c}{t}"

proc getDeviceId(): string {.inline.} =
  "e" & fmt"{rand(1.0 - 1e-8):.15f}"[2 .. ^1]

proc newWxClient*(): WxClient =
  result.new
  result.setCookies({
    "pgv_pvi": getPgv(),
    "pgv_si": getPgv("s"),
  })
  result.deviceId = getDeviceId()

proc createClient(self: WxClient,
  headers: openArray[(string, string)],
  maxRedirects: int,
): AsyncHttpClient =
  result = newAsyncHttpClient(maxRedirects = maxRedirects)
  result.headers = newHttpheaders({
    "user-agent": USER_AGENT,
    "connection": "close",
  })
  if headers.len > 0:
    for (k, v) in headers:
      result.headers[k] = v
  if self.cookies.len > 0:
    result.headers["cookie"] = self.cookies.pairs.toSeq.mapIt(&"{it[0]}={it[1]}").join("; ")

proc setCookies(self: WxClient, headers: HttpHeaders) =
  if "set-cookie" notin headers.table: return
  for s in headers.table["set-cookie"]:
    let kv = s.split(";")[0].split("=")
    let (k, v) = (kv[0].strip, kv[1].strip)
    # echo (k, v)
    self.cookies[k] = v

proc request(self: WxClient,
  url: string,
  httpMethod: HttpMethod,
  params: seq[(string, string)],
  headers: seq[(string, string)],
  body: string,
  maxRedirects: int,
): Future[string] {.async.} =
  let client = self.createClient(headers = headers, maxRedirects = maxRedirects)
  try:
    var uri = url.parseUri
    uri = uri ? (uri.query.decodeQuery.toSeq & params)

    # echo (httpMethod, uri, client.headers, body)
    let res = await client.request(uri, body = body, httpMethod = httpMethod)
    # echo res.code
    self.setCookies(res.headers)
    result = await res.body
  finally:
    try:
      client.close
    except:
      logging.warn getCurrentExceptionMsg()

proc request(self: WxClient,
  url: string,
  httpMethod = HttpGet,
  params: seq[(string, string)] = @[],
  headers: seq[(string, string)] = @[],
  data: seq[(string, string)] = @[],
  maxRedirects = 5,
): Future[string] {.async, inline.} =
  let body = data.encodeQuery
  return await self.request(url, httpMethod, params, headers, body, maxRedirects)

proc request(self: WxClient,
  url: string,
  httpMethod = HttpGet,
  params: seq[(string, string)] = @[],
  headers: seq[(string, string)] = @[],
  data: JsonNode = %*{},
  maxRedirects = 5,
): Future[string] {.async, inline.} =
  let body = if data.len > 0: $data else: ""
  return await self.request(url, httpMethod, params, headers, body, maxRedirects)

proc getKeyVal(src, keyName: string): Option[string] =
  var matches: array[1, string]
  let p = (&""" '{keyName}' \s* '=' \s* {{(!\; .)+}} \s* ';'? """).peg
  if src.contains(p, matches):
    if matches[0].startsWith("\"") and matches[0].endsWith("\""): some(matches[0][1 ..< ^1])
    else: some(matches[0])
  else: none(string)

proc getUUID*(self: WxClient): Future[string] {.async.} =
  let res = await self.request(JS_LOGIN_URL, httpMethod = HttpPost)
  let codeOpt = res.getKeyVal("window.QRLogin.code")
  if codeOpt.isSome and codeOpt.get == "200":
    let uuidOpt = res.getKeyVal("window.QRLogin.uuid")
    if uuidOpt.isSome:
      return uuidOpt.get
  raise newException(CatchableError, "getUUID error: " & res)

proc getLoginUrl*(self: WxClient, uuid: string): string {.inline.} =
  "https://login.weixin.qq.com/l/" & uuid

proc getLoginR(): string {.inline.} =
  $((getTimestamp() and 0xffffffff).uint32.bitnot)

proc checkLogin*(self: WxClient, uuid: string): Future[string] {.async.} =
  let params = {
    "tip": "0",
    "uuid": uuid,
    "loginicon": "true",
    "r": getLoginR(),
  }.toSeq
  while true:
    let res = await self.request(API_LOGIN_URL, params = params)
    let codeOpt = res.getKeyVal("window.code")
    if codeOpt.isSome:
      let code = codeOpt.get
      if code == "200":
        let redirectUriOpt = res.getKeyVal("window.redirect_uri")
        if redirectUriOpt.isSome:
          return redirectUriOpt.get
      elif code.startsWith("2"):
        continue
    raise newException(CatchableError, "checkLogin error: " & res)

proc getEncKeyVal(src, key: string): Option[string] =
  let pat = (&""" '<{key}>' {{(!\< .)+}} '</{key}>' """).peg
  var matches: array[1, string]
  if src.contains(pat, matches): some(matches[0])
  else: none(string)

proc login*(self: WxClient, redirectUrl: string) {.async.} =
  let headers = {
    "client-version": "2.0.0",
    "referer": "https://wx.qq.com/?&lang=" & LANG & "&target=t",
    "extspam": "Go8FCIkFEokFCggwMDAwMDAwMRAGGvAESySibk50w5Wb3uTl2c2h64jVVrV7gNs06GFlWplHQbY/5FfiO++1yH4ykCyNPWKXmco+wfQzK5R98D3so7rJ5LmGFvBLjGceleySrc3SOf2Pc1gVehzJgODeS0lDL3/I/0S2SSE98YgKleq6Uqx6ndTy9yaL9qFxJL7eiA/R3SEfTaW1SBoSITIu+EEkXff+Pv8NHOk7N57rcGk1w0ZzRrQDkXTOXFN2iHYIzAAZPIOY45Lsh+A4slpgnDiaOvRtlQYCt97nmPLuTipOJ8Qc5pM7ZsOsAPPrCQL7nK0I7aPrFDF0q4ziUUKettzW8MrAaiVfmbD1/VkmLNVqqZVvBCtRblXb5FHmtS8FxnqCzYP4WFvz3T0TcrOqwLX1M/DQvcHaGGw0B0y4bZMs7lVScGBFxMj3vbFi2SRKbKhaitxHfYHAOAa0X7/MSS0RNAjdwoyGHeOepXOKY+h3iHeqCvgOH6LOifdHf/1aaZNwSkGotYnYScW8Yx63LnSwba7+hESrtPa/huRmB9KWvMCKbDThL/nne14hnL277EDCSocPu3rOSYjuB9gKSOdVmWsj9Dxb/iZIe+S6AiG29Esm+/eUacSba0k8wn5HhHg9d4tIcixrxveflc8vi2/wNQGVFNsGO6tB5WF0xf/plngOvQ1/ivGV/C1Qpdhzznh0ExAVJ6dwzNg7qIEBaw+BzTJTUuRcPk92Sn6QDn2Pu3mpONaEumacjW4w6ipPnPw+g2TfywJjeEcpSZaP4Q3YV5HG8D6UjWA4GSkBKculWpdCMadx0usMomsSS/74QgpYqcPkmamB4nVv1JxczYITIqItIKjD35IGKAUwAA==",
  }.toSeq
  let res = await self.request(redirectUrl, headers = headers, maxRedirects = 0)
  let retOpt = res.getEncKeyVal("ret")
  if retOpt.isSome and retOpt.get == "0":
    self.props.skey = res.getEncKeyVal("skey").get
    self.props.sid = res.getEncKeyVal("wxsid").get
    self.props.uin = res.getEncKeyVal("wxuin").get
    self.props.passTicket = res.getEncKeyVal("pass_ticket").get
    return
  raise newException(CatchableError, "Login error: " & res)

proc getInitR(): string {.inline.} =
  $(getTimestamp() div -1579)

proc getBaseRequest(self: WxClient): JsonNode {.inline.} =
  %*{
    "Uin": self.props.uin.parseInt,
    "Sid": self.props.sid,
    "Skey": self.props.skey,
    "DeviceID": self.deviceId,
  }

# const SYNCCHECK_RET_LOGOUT == 1101

proc formatSyncKey(jso: JsonNode): string {.inline.} =
  jso.toSeq.mapIt($(it["Key"].getInt) & "_" & $(it["Val"].getInt)).join("|")

proc updateSyncKey(self: WxClient, jso: JsonNode) =
  self.props.skey = jso["SKey"].getStr(self.props.skey)
  if "SyncKey" in jso:
    self.props.syncKey = jso["SyncKey"]
  if "SyncCheckKey" in jso:
    self.props.formatedSyncKey = formatSyncKey(jso["SyncCheckKey"]["List"])
  elif self.props.formatedSyncKey.len == 0 and "SyncKey" in jso:
    self.props.formatedSyncKey = formatSyncKey(jso["SyncKey"]["List"])

proc init*(self: WxClient): Future[JsonNode] {.async.} =
  let params = {
    "pass_ticket": self.props.passTicket,
    "r": getInitR(),
  }.toSeq
  let data = %*{
    "BaseRequest": self.getBaseRequest
  }
  let res = await self.request(API_WEBWX_INIT, params = params, data = data, httpMethod = HttpPost)
  result = res.parseJson
  if result["BaseResponse"]["Ret"].getInt != 0:
    raise newException(CatchableError, $result)
  self.updateSyncKey(result)

proc notifyMobile*(self: WxClient,
  fromUserName: string, toUserName = ""
): Future[JsonNode] {.async.} =
  let params = {
    "pass_ticket": self.props.passTicket,
    "lang": LANG,
  }.toSeq
  let data = %*{
    "BaseRequest": self.getBaseRequest,
    "Code": if toUserName.len > 0: 1 else: 3,
    "FromUserName": fromUserName,
    "ToUserName": if toUserName.len > 0: toUserName else: fromUserName,
    "ClientMsgId": getTimestamp(),
  }
  let res = await self.request(API_WEBWX_STATUS_NOTIFY, params = params, data = data, httpMethod = HttpPost)
  result = res.parseJson
  if result["BaseResponse"]["Ret"].getInt != 0:
    raise newException(CatchableError, $result)

proc getContact*(self: WxClient,
  suc = 0,
): Future[JsonNode] {.async.} =
  let params = {
    "seq": $suc,
    "skey": self.props.skey,
    "r": $getTimestamp(),
  }.toSeq
  let res = await self.request(API_WEBWX_GET_CONTACT, params = params)
  result = res.parseJson
  if result["BaseResponse"]["Ret"].getInt != 0:
    raise newException(CatchableError, "get context error: " & res)

proc batchGetContact*(self: WxClient,
  users: seq[(string, string)],
): Future[JsonNode] {.async.} =
  let params = {
    "pass_ticket": self.props.passTicket,
    "type": "ex",
    "r": $getTimestamp(),
    "lang": LANG,
  }.toSeq
  let data = %*{
    "BaseRequest": self.getBaseRequest,
    "Count": users.len,
    "List": %*users.mapIt(%*{ "UserName": it[0], "EncryChatRoomId": it[1] }),
  }
  let res = await self.request(API_WEBWX_BATCH_GET_CONTACT, params = params, data = data, httpMethod = HttpPost)
  result = res.parseJson
  if result["BaseResponse"]["Ret"].getInt != 0:
    raise newException(CatchableError, "Batch get contact error: " & res)



const SYNC_CHECK_RET_SUCCESS = "0"
const SYNC_CHECK_RET_LOGOUT = "1101"

const SYNC_CHECK_SELECTOR_NORMAL* = "0"

proc parseSyncCheckRes(s: string): JsonNode =
  result = %*{}
  var s = s.strip
  if s.startsWith("{"): s = s[1 ..< ^1]
  for kv in s.split(","):
    let parts = kv.split(":")
    let (k, v) = (parts[0].strip, parts[1].strip)
    result[k] = v.parseJson

proc syncCheck*(self: WxClient): Future[string] {.async.} =
  let params = {
    "r": $getTimestamp(),
    "sid": self.props.sid,
    "uin": self.props.uin,
    "skey": self.props.skey,
    "deviceId": self.deviceId,
    "syncKey": self.props.formatedSyncKey,
  }.toSeq
  let res = await self.request(API_SYNC_CHECK, params = params)
  let jso = res.getKeyVal("window.synccheck").get.parseSyncCheckRes
  if jso["retcode"].getStr != SYNC_CHECK_RET_SUCCESS:
    raise newException(CatchableError, "sync check error: " & res)
  return jso["selector"].getStr

proc sync*(self: WxClient): Future[JsonNode] {.async.} =
  let params = {
    "sid": self.props.sid,
    "skey": self.props.skey,
    "pass_ticket": self.props.passTicket,
    "lang": LANG,
  }.toSeq
  let data = %*{
    "BaseRequest": self.getBaseRequest,
    "SyncKey": self.props.syncKey,
    "rr": getTimestamp(),
  }
  let res = await self.request(API_WEBWX_SYNC, params = params, data = data, httpMethod = HttpPost)
  result = res.parseJson
  if result["BaseResponse"]["Ret"].getInt != 0:
    raise newException(CatchableError, $result)
  self.updateSyncKey(result)

proc getClientMsgId(): int64 {.inline.} =
  getTimestamp() * 1000

proc sendText*(self: WxClient, fromUser, toUser, text: string): Future[JsonNode] {.async.} =
  let params = {
    "pass_ticket": self.props.passTicket,
    "lang": LANG,
  }.toSeq
  let clientMsgId = getClientMsgId()
  let data = %*{
    "BaseRequest": self.getBaseRequest,
    "Scene": 0,
    "Msg": %*{
      "Type": WX_MSG_TYPE_TEXT,
      "Content": text,
      "FromUserName": fromUser,
      "ToUserName": toUser,
      "LocalID": clientMsgId,
      "ClientMsgId": clientMsgId,
    },
  }
  let res = await self.request(API_WEBWX_SEND_MSG, params = params, data = data, httpMethod = HttpPost)
  result = res.parseJson
  if result["BaseResponse"]["Ret"].getInt != 0:
    raise newException(CatchableError, $result)