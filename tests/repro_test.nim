import std/[strutils, unicode]
import ../src/threecodex/[types, app, backend]

proc stripBulletLocal(s: string): string =
  var i = 0
  while i < s.len and s[i] notin {'a'..'z','A'..'Z','0'..'9','"','\'','('}:
    inc i
  s[i .. ^1]

let content = "Hi. We're in 3cx on master with one uncommitted change. What would you like to work on?"
var chat = Chat()
chat.addMessage(rAssistant, content, "commandcode.z-ai/glm-5.3-flash")
var application = App(chat: chat, backend: newMockBackend("test"), streamIdx: 0, streaming: false)
echo "streamed before: ", application.chat.messages[0].content.repr
# tool chunk as from headless hook
applyChunk(application, Chunk(kind: ckTool, text: "● " & content))
echo "messages after: ", application.chat.messages.len
for m in application.chat.messages:
  echo "  ", m.role, ": ", m.content.repr
