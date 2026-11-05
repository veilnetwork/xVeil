import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

func emit(_ row: [String: Any]) {
  let d = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
  print(String(data: d, encoding: .utf8)!)
  fflush(stdout)
}
func check(_ status: OSStatus, _ step: String) throws {
  if status != noErr { throw NSError(domain: "qa.output", code: Int(status), userInfo: [NSLocalizedDescriptionKey: step]) }
}
func u32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
         _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
         _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> UInt32? {
  var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
  guard AudioObjectHasProperty(object, &addr) else { return nil }
  var value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
  guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
  return value
}
func f32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
         _ element: AudioObjectPropertyElement) -> Float32? {
  var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
  guard AudioObjectHasProperty(object, &addr) else { return nil }
  var value: Float32 = 0, size = UInt32(MemoryLayout<Float32>.size)
  guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
  return value
}
func stringProp(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
  var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
  var value: Unmanaged<CFString>? = nil, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
  guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
  return value?.takeRetainedValue() as String?
}
func run() throws {
  var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
  var bytes: UInt32 = 0
  try check(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &bytes), "device size")
  var devices = [AudioDeviceID](repeating: 0, count: Int(bytes) / MemoryLayout<AudioDeviceID>.size)
  try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &bytes, &devices), "devices")
  let speakers = devices.filter { device in
    guard u32(device, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn,
          u32(device, kAudioDevicePropertyDeviceIsAlive) == 1,
          let uid = stringProp(device, kAudioDevicePropertyDeviceUID) else { return false }
    return uid == "BuiltInSpeakerDevice"
  }
  guard speakers.count == 1 else { throw NSError(domain: "qa.output", code: 1, userInfo: [NSLocalizedDescriptionKey: "unique built-in speaker not found"]) }
  let device = speakers[0]
  let defaultBefore = u32(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
  let muted = u32(device, kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
  let volume = f32(device, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain)
    ?? f32(device, kAudioDevicePropertyVolumeScalar, 1)
  emit(["event": "output_inspected", "builtinSpeakerFound": true,
        "isDefault": defaultBefore == device, "muteKnown": muted != nil,
        "muted": muted == 1, "volumeKnown": volume != nil, "volume": volume ?? -1])
  if CommandLine.arguments.count == 1 { return }
  guard muted != 1 && (volume == nil || volume! > 0) else {
    throw NSError(domain: "qa.output", code: 2, userInfo: [NSLocalizedDescriptionKey: "built-in output is muted; no system controls changed"])
  }
  let file = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[1]))
  let engine = AVAudioEngine()
  guard let unit = engine.outputNode.audioUnit else { throw NSError(domain: "qa.output", code: 3) }
  var selected = device
  try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &selected, UInt32(MemoryLayout<AudioDeviceID>.size)), "set stream output")
  var actual: AudioDeviceID = 0, size = UInt32(MemoryLayout<AudioDeviceID>.size)
  try check(AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &actual, &size), "read stream output")
  guard actual == device else { throw NSError(domain: "qa.output", code: 4) }
  let player = AVAudioPlayerNode()
  engine.attach(player)
  engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
  let gain: Float = CommandLine.arguments.count > 2 ? Float(CommandLine.arguments[2]) ?? -1 : 0.5
  guard gain >= 0.25 && gain <= 1 else { throw NSError(domain: "qa.output", code: 7) }
  engine.mainMixerNode.outputVolume = gain
  let done = DispatchSemaphore(value: 0)
  player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { _ in done.signal() }
  engine.prepare()
  try engine.start()
  player.play()
  var actualStarted: AudioDeviceID = 0
  size = UInt32(MemoryLayout<AudioDeviceID>.size)
  try check(AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &actualStarted, &size), "read started output")
  guard actualStarted == device else { player.stop(); engine.stop(); throw NSError(domain: "qa.output", code: 6) }
  emit(["event": "playback_started", "uptime_ns": DispatchTime.now().uptimeNanoseconds,
        "wall_s": Date().timeIntervalSince1970, "frames": file.length,
        "rate": file.processingFormat.sampleRate, "streamOutputVerified": true, "streamGain": gain,
        "systemDefaultUnchanged": defaultBefore == u32(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)])
  let duration = Double(file.length) / file.processingFormat.sampleRate
  let result = done.wait(timeout: .now() + duration + 5)
  let rendered = player.lastRenderTime.flatMap { player.playerTime(forNodeTime: $0) }?.sampleTime ?? -1
  player.stop()
  engine.stop()
  emit(["event": "playback_finished", "uptime_ns": DispatchTime.now().uptimeNanoseconds,
        "wall_s": Date().timeIntervalSince1970, "completionReceived": result == .success,
        "renderedFrames": rendered, "systemDefaultUnchanged": defaultBefore == u32(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)])
  guard result == .success else { throw NSError(domain: "qa.output", code: 5) }
}
do { try run() } catch let e as NSError {
  emit(["event": "failed", "code": e.code, "stage": e.domain == "qa.output" ? e.localizedDescription : "audio operation failed"]); exit(1)
}
