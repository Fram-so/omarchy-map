// Development harness: run the service in a second Quickshell instance so a
// broken component fails on its own instead of taking the live bar down.
//   quickshell -p <plugin-dir>/shell.qml
//   quickshell ipc -p <plugin-dir>/shell.qml call fram.kartet status
// Ignored by the Omarchy plugin loader (manifest points at Service.qml).
import Quickshell

ShellRoot {
  Service {}
}
