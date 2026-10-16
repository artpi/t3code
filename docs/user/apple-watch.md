# Apple Watch companion

Builds of this fork that include the Apple Watch companion let you browse
threads, read conversations, send replies, and start threads in existing
projects. Pair your iPhone app with your environments first, then open T3 Code
on the paired watch. The companion requires your iPhone.

Turn the Digital Crown or swipe to scroll, and tap a thread to open it.
Pressing the crown keeps its normal watchOS system behavior.

To reply, tap Respond to open native text entry and use its microphone to dictate.
Accepting the text sends it with the thread's existing settings and returns to
the conversation, with your reply and its delivery status at the top. Cancelling
text entry sends nothing. To start a thread, choose
New thread and review the selected project alongside your prompt. The Watch
remembers your last project; tap Project to change it without losing your message.
Choose a model from the available models you have starred on your iPhone.
Workspace and runtime settings use the project's defaults, configured on your iPhone.
Starting a thread opens its conversation immediately, with your first message and
delivery status visible while the iPhone creates the thread.

Delivery distinguishes a message saved on the watch, queued on the iPhone,
and accepted by the server. Acceptance means the server received the message;
the agent may still be preparing or working on an earlier turn. Replies queue
behind ongoing work. Pending replies update in the conversation; reconnecting
automatically checks delivery without sending a second copy. A queued message can be
cancelled until delivery starts. Failed or cancelled submissions keep the draft.

Cached content remains readable during disconnection. Open T3 Code on your
iPhone if the watch asks you to reconnect or refresh. Dictation availability
depends on the language and system input methods supported by your watch.
