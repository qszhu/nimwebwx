import std/[
  logging,
  sequtils,
  strutils,
  tables,
]

import wxclient, types

export json
export consts, types, asyncdispatch



type
  WechatDelegate* = ref object of RootObj
    wechat*: Wechat

  Wechat* = ref object
    client: WxClient
    contacts: Table[string, WxContact]
    user: WxContact
    delegate: WechatDelegate
    syncInterval: int

method onMessage(self: WechatDelegate, msg: WxMessage) {.async, base.} = discard
method onSync(self: WechatDelegate) {.async, base.} = discard

proc newWechat*(delegate: WechatDelegate = WechatDelegate.new, syncInterval = 1000): Wechat =
  result.new
  result.client = newWxClient()
  result.delegate = delegate
  delegate.wechat = result
  result.syncInterval = syncInterval

proc updateContact(self: Wechat, jso: JsonNode) =
  let c = newWxContact(jso)
  self.contacts[c.userName] = c

proc getAllContacts(self: Wechat): Future[seq[WxContact]] {.async.} =
  var suc = 0
  var res = newSeq[WxContact]()
  while true:
    let resp = await self.client.getContact(suc)
    for c in resp["MemberList"]:
      res.add newWxContact(c)
    suc = resp["Seq"].getInt
    if suc == 0: break
  let emptyGroups = res.filterIt(it.isGroup and it.memberCount == 0)
  logging.debug "empty groups: ", emptyGroups.len
  return res

proc getLoginUrl*(self: Wechat): Future[(string, string)] {.async.} =
  let uuid = await self.client.getUUID
  let loginUrl = self.client.getLoginUrl(uuid)
  (loginUrl, uuid)

proc start*(self: Wechat, uuid: string) {.async.} =
  let redirectUri = await self.client.checkLogin(uuid)
  await self.client.login(redirectUri)

  block:
    let res = await self.client.init
    self.user = newWxContact(res["User"])
    for c in res["ContactList"]:
      self.updateContact(c)
    logging.debug "Contacts: ", self.contacts.len

  block:
    let res = await self.client.notifyMobile(self.user.userName)
    logging.notice "notify mobile: ", res

  block:
    let res = await self.getAllContacts
    for c in res:
      self.contacts[c.userName] = c
    logging.notice "Contacts: ", self.contacts.len

  block:
    while true:
      try:
        let selector = await self.client.syncCheck
        if selector != SYNC_CHECK_SELECTOR_NORMAL:
          let res = await self.client.sync
          if res{"AddMsgCount"}.getInt > 0:
            for msg in res["AddMsgList"]:
              await self.delegate.onMessage(msg.newWxMessage)
        await self.delegate.onSync
      except:
        logging.error getCurrentExceptionMsg()
      await sleepAsync(self.syncInterval)

proc sendText*(self: Wechat, userName, text: string): Future[JsonNode] {.async.} =
  let res = await self.client.sendText(self.user.userName, userName, text)
  return res

proc updateContacts*(self: Wechat, roomUserName: string, roomId = "") {.async.} =
  let res = await self.client.batchGetContact(@[(roomUserName, roomId)])
  for c in res["ContactList"]:
    self.updateContact(c)
    for c1 in c["MemberList"]:
      self.updateContact(c1)

proc getContactInRoom*(self: Wechat, userName, roomUserName: string): Future[WxContact] {.async.} =
  if userName notin self.contacts or self.contacts[userName].nickName.len == 0:
    await self.updateContacts(roomUserName)
    # let roomId = self.contacts[roomUserName].raw["EncryChatRoomId"].getStr
    # await self.updateContacts(roomUserName, roomId)
  self.contacts[userName]
