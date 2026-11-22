//
//  AudioEnginePlayer.swift
//  KSPlayer
//
//  Created by kintan on 2018/3/11.
//

import AVFoundation
import CoreAudio
import Foundation

public protocol AudioOutput: FrameOutput {
    var playbackRate: Float { get set }
    var volume: Float { get set }
    var isMuted: Bool { get set }
    init()
    func prepare(audioFormat: AVAudioFormat)
}

public protocol AudioDynamicsProcessor {
    var audioUnitForDynamicsProcessor: AudioUnit { get }
}

public extension AudioDynamicsProcessor {
    var attackTime: Float {
        get {
            var value = AudioUnitParameterValue(1.0)
            AudioUnitGetParameter(audioUnitForDynamicsProcessor, kDynamicsProcessorParam_AttackTime, kAudioUnitScope_Global, 0, &value)
            return value
        }
        set {
            AudioUnitSetParameter(audioUnitForDynamicsProcessor, kDynamicsProcessorParam_AttackTime, kAudioUnitScope_Global, 0, AudioUnitParameterValue(newValue), 0)
        }
    }

    var releaseTime: Float {
        get {
            var value = AudioUnitParameterValue(1.0)
            AudioUnitGetParameter(audioUnitForDynamicsProcessor, kDynamicsProcessorParam_ReleaseTime, kAudioUnitScope_Global, 0, &value)
            return value
        }
        set {
            AudioUnitSetParameter(audioUnitForDynamicsProcessor, kDynamicsProcessorParam_ReleaseTime, kAudioUnitScope_Global, 0, AudioUnitParameterValue(newValue), 0)
        }
    }

    var threshold: Float {
        get {
            var value = AudioUnitParameterValue(1.0)
            AudioUnitGetParameter(audioUnitForDynamicsProcessor, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, &value)
            return value
        }
        set {
            AudioUnitSetParameter(audioUnitForDynamicsProcessor, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, AudioUnitParameterValue(newValue), 0)
        }
    }

    var expansionRatio: Float {
        get {
            var value = AudioUnitParameterValue(1.0)
            AudioUnitGetParameter(audioUnitForDynamicsProcessor, kDynamicsProcessorParam_ExpansionRatio, kAudioUnitScope_Global, 0, &value)
            return value
        }
        set {
            AudioUnitSetParameter(audioUnitForDynamicsProcessor, kDynamicsProcessorParam_ExpansionRatio, kAudioUnitScope_Global, 0, AudioUnitParameterValue(newValue), 0)
        }
    }

    var overallGain: Float {
        get {
            var value = AudioUnitParameterValue(1.0)
            AudioUnitGetParameter(audioUnitForDynamicsProcessor, kDynamicsProcessorParam_OverallGain, kAudioUnitScope_Global, 0, &value)
            return value
        }
        set {
            AudioUnitSetParameter(audioUnitForDynamicsProcessor, kDynamicsProcessorParam_OverallGain, kAudioUnitScope_Global, 0, AudioUnitParameterValue(newValue), 0)
        }
    }
}

public final class AudioEngineDynamicsPlayer: AudioEnginePlayer, AudioDynamicsProcessor {
    private let dynamicsProcessor = AVAudioUnitEffect(audioComponentDescription:
        AudioComponentDescription(componentType: kAudioUnitType_Effect,
                                  componentSubType: kAudioUnitSubType_DynamicsProcessor,
                                  componentManufacturer: kAudioUnitManufacturer_Apple,
                                  componentFlags: 0,
                                  componentFlagsMask: 0))
    public var audioUnitForDynamicsProcessor: AudioUnit {
        dynamicsProcessor.audioUnit
    }

    override func audioNodes() -> [AVAudioNode] {
        var nodes: [AVAudioNode] = [dynamicsProcessor]
        nodes.append(contentsOf: super.audioNodes())
        return nodes
    }

    public required init() {
        super.init()
        engine.attach(dynamicsProcessor)
    }
}

public class AudioEnginePlayer: AudioOutput {
    public let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var sourceNodeAudioFormat: AVAudioFormat?
    private var outputIntent = PlaybackAudioOutputIntent()
    private var configurationObserver: NSObjectProtocol?
    private var configurationWork: DispatchWorkItem?
    private var startRetry: DispatchWorkItem?
    private var startRetryID = UUID()
    private var starter = PlaybackAudioStarter()
    public var onFailure: ((NSError) -> Void)?
    private var graphGeneration: UInt64 = 0
    private var rebuildingGraph = false
    private var needsGraphRebuild = false

//    private let reverb = AVAudioUnitReverb()
//    private let nbandEQ = AVAudioUnitEQ()
//    private let distortion = AVAudioUnitDistortion()
//    private let delay = AVAudioUnitDelay()
    private let timePitch = AVAudioUnitTimePitch()
    private var sampleSize = UInt32(MemoryLayout<Float>.size)
    private var currentRenderReadOffset = UInt32(0)
    private var outputLatency = TimeInterval(0)
    public weak var renderSource: OutputRenderSourceDelegate?
    private var currentRender: AudioFrame? {
        didSet {
            if currentRender == nil {
                currentRenderReadOffset = 0
            }
        }
    }

    public var playbackRate: Float {
        get {
            timePitch.rate
        }
        set {
            timePitch.rate = min(32, max(1 / 32, newValue))
        }
    }

    public var volume: Float {
        get { outputIntent.volume }
        set {
            outputIntent.setVolume(newValue)
            sourceNode?.volume = outputIntent.volume
        }
    }

    public var isMuted: Bool {
        get {
            engine.mainMixerNode.outputVolume == 0.0
        }
        set {
            engine.mainMixerNode.outputVolume = newValue ? 0.0 : 1.0
        }
    }

    public required init() {
        engine.attach(timePitch)
        if let audioUnit = engine.outputNode.audioUnit {
            addRenderNotify(audioUnit: audioUnit)
        }
        #if !os(macOS)
        outputLatency = AVAudioSession.sharedInstance().outputLatency
        #endif
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main) { [weak self] _ in self?.configurationChanged() }
    }

    deinit {
        configurationWork?.cancel()
        startRetry?.cancel()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        engine.stop()
        if let audioUnit = engine.outputNode.audioUnit {
            AudioUnitRemoveRenderNotify(audioUnit, Self.renderNotify, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    public func prepare(audioFormat: AVAudioFormat) {
        guard sourceNodeAudioFormat != audioFormat || needsGraphRebuild else { return }
        let changedFormat = sourceNodeAudioFormat != audioFormat
        guard !rebuildingGraph else { needsGraphRebuild = true; return }
        rebuildingGraph = true
        needsGraphRebuild = false
        graphGeneration &+= 1
        cancelStartRetry()
        if changedFormat { starter.reset() }
        defer {
            rebuildingGraph = false
            if needsGraphRebuild { configurationChanged() }
        }
        #if !os(macOS)
        try? AVAudioSession.sharedInstance().setPreferredOutputNumberOfChannels(Int(audioFormat.channelCount))
        KSLog("[audio] set preferredOutputNumberOfChannels: \(audioFormat.channelCount)")
        #endif
        KSLog("[audio] outputFormat AudioFormat: \(audioFormat)")
        if let channelLayout = audioFormat.channelLayout {
            KSLog("[audio] outputFormat channelLayout \(channelLayout.channelDescriptions)")
        }
        let rate = timePitch.rate, mixerVolume = engine.mainMixerNode.outputVolume
        engine.stop()
        currentRender = nil
        if let sourceNode {
            engine.disconnectNodeOutput(sourceNode)
            engine.detach(sourceNode)
        }
        engine.reset()
        sourceNodeAudioFormat = audioFormat
        sourceNode = AVAudioSourceNode(format: audioFormat) { [weak self] _, timestamp, frameCount, audioBufferList in
            if timestamp.pointee.mSampleTime == 0 {
                return noErr
            }
            self?.audioPlayerShouldInputData(ioData: UnsafeMutableAudioBufferListPointer(audioBufferList), numberOfFrames: frameCount)
            return noErr
        }
        guard let sourceNode else {
            return
        }
        KSLog("[audio] new sourceNode inputFormat: \(sourceNode.inputFormat(forBus: 0))")
        sampleSize = audioFormat.sampleSize
        sourceNode.volume = outputIntent.volume
        engine.attach(sourceNode)
        var nodes: [AVAudioNode] = [sourceNode]
        nodes.append(contentsOf: audioNodes())
        if audioFormat.channelCount > 2 {
            nodes.append(engine.outputNode)
        }
        // 一定要传入format，这样多音轨音响才不会有问题。
        engine.connect(nodes: nodes, format: audioFormat)
        timePitch.rate = rate
        engine.mainMixerNode.outputVolume = mixerVolume
        engine.prepare()
        ensureRunningIfRequested()
    }

    private func configurationChanged() {
        needsGraphRebuild = true
        guard !outputIntent.interrupted, !rebuildingGraph, configurationWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.configurationWork = nil
            guard !self.outputIntent.interrupted else { return }
            guard let format = self.sourceNodeAudioFormat else { return }
            self.prepare(audioFormat: format)
        }
        configurationWork = work
        DispatchQueue.main.async(execute: work)
    }

    func setAudioSessionInterrupted(_ value: Bool) {
        outputIntent.setInterrupted(value)
        cancelStartRetry(); starter.reset()
        if value, engine.isRunning { engine.pause() }
        if !value, needsGraphRebuild { configurationChanged() }
    }

    func ensureRunningIfRequested() {
        guard outputIntent.canRun, sourceNode != nil, startRetry == nil else { return }
        if needsGraphRebuild, !rebuildingGraph, let format = sourceNodeAudioFormat {
            prepare(audioFormat: format)
            return
        }
        switch starter.attempt(revision: outputIntent.revision,
                               allowed: outputIntent.canRun, running: engine.isRunning, start: {
            try engine.start()
            guard engine.isRunning else {
                throw NSError(domain: PlaybackAudioFailure.domain, code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "音频设备尚未启动。"])
            }
        }) {
        case .idle, .running: break
        case let .retry(delay): scheduleStartRetry(after: delay)
        case let .failed(error):
            KSLog(error)
            onFailure?(PlaybackAudioFailure.startup(error))
        }
    }

    private func cancelStartRetry() {
        startRetryID = UUID(); startRetry?.cancel(); startRetry = nil
    }
    private func scheduleStartRetry(after delay: TimeInterval) {
        guard startRetry == nil, sourceNode != nil else { return }
        let ticket = UUID(); startRetryID = ticket
        let revision = outputIntent.revision, generation = graphGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.startRetryID == ticket else { return }
            self.startRetry = nil
            guard self.graphGeneration == generation, self.outputIntent.acceptsRestart(revision: revision) else { return }
            self.ensureRunningIfRequested()
        }
        startRetry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func audioNodes() -> [AVAudioNode] {
        [timePitch, engine.mainMixerNode]
    }

    public func play() {
        outputIntent.setPlaying(true)
        cancelStartRetry()
        if needsGraphRebuild, let format = sourceNodeAudioFormat { prepare(audioFormat: format) }
        else { ensureRunningIfRequested() }
    }

    public func pause() {
        outputIntent.setPlaying(false)
        cancelStartRetry(); starter.reset()
        if engine.isRunning {
            engine.pause()
        }
    }

    public func flush() {
        // Flush only after the source callback is quiescent. A route change
        // may call flush while output is running, unlike a serialized seek.
        if engine.isRunning { engine.pause() }
        currentRender = nil
        #if !os(macOS)
        // 这个要在主线程执行，如果在音频的线程，那就会有中断杂音
        outputLatency = AVAudioSession.sharedInstance().outputLatency
        #endif
        if needsGraphRebuild, let format = sourceNodeAudioFormat { prepare(audioFormat: format) }
        else { ensureRunningIfRequested() }
    }

    private static let renderNotify: AURenderCallback = { refCon, ioActionFlags, inTimeStamp, _, _, _ in
        let player = Unmanaged<AudioEnginePlayer>.fromOpaque(refCon).takeUnretainedValue()
        autoreleasepool {
            if ioActionFlags.pointee.contains(.unitRenderAction_PostRender) {
                player.audioPlayerDidRenderSample(sampleTimestamp: inTimeStamp.pointee)
            }
        }
        return noErr
    }

    private func addRenderNotify(audioUnit: AudioUnit) {
        AudioUnitAddRenderNotify(audioUnit, Self.renderNotify, Unmanaged.passUnretained(self).toOpaque())
    }

//    private func addRenderCallback(audioUnit: AudioUnit, streamDescription: UnsafePointer<AudioStreamBasicDescription>) {
//        _ = AudioUnitSetProperty(audioUnit,
//                                 kAudioUnitProperty_StreamFormat,
//                                 kAudioUnitScope_Input,
//                                 0,
//                                 streamDescription,
//                                 UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
//        var inputCallbackStruct = AURenderCallbackStruct()
//        inputCallbackStruct.inputProcRefCon = Unmanaged.passUnretained(self).toOpaque()
//        inputCallbackStruct.inputProc = { refCon, _, _, _, inNumberFrames, ioData in
//            guard let ioData else {
//                return noErr
//            }
//            let `self` = Unmanaged<AudioEnginePlayer>.fromOpaque(refCon).takeUnretainedValue()
//            self.audioPlayerShouldInputData(ioData: UnsafeMutableAudioBufferListPointer(ioData), numberOfFrames: inNumberFrames)
//            return noErr
//        }
//        _ = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &inputCallbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
//    }

    private func audioPlayerShouldInputData(ioData: UnsafeMutableAudioBufferListPointer, numberOfFrames: UInt32) {
        var ioDataWriteOffset = 0
        var numberOfSamples = numberOfFrames
        while numberOfSamples > 0 {
            if currentRender == nil {
                currentRender = renderSource?.getAudioOutputRender()
            }
            guard let currentRender else {
                break
            }
            let residueLinesize = currentRender.numberOfSamples - currentRenderReadOffset
            guard residueLinesize > 0 else {
                self.currentRender = nil
                continue
            }
            if sourceNodeAudioFormat != currentRender.audioFormat {
                for buffer in ioData {
                    if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                }
                runOnMainThread { [weak self] in
                    guard let self else {
                        return
                    }
                    self.prepare(audioFormat: currentRender.audioFormat)
                }
                return
            }
            let framesToCopy = min(numberOfSamples, residueLinesize)
            let bytesToCopy = Int(framesToCopy * sampleSize)
            let offset = Int(currentRenderReadOffset * sampleSize)
            for i in 0 ..< min(ioData.count, currentRender.data.count) {
                if let source = currentRender.data[i], let destination = ioData[i].mData {
                    (destination + ioDataWriteOffset).copyMemory(from: source + offset, byteCount: bytesToCopy)
                }
            }
            numberOfSamples -= framesToCopy
            ioDataWriteOffset += bytesToCopy
            currentRenderReadOffset += framesToCopy
        }
        let sizeCopied = (numberOfFrames - numberOfSamples) * sampleSize
        for i in 0 ..< ioData.count {
            let sizeLeft = Int(ioData[i].mDataByteSize - sizeCopied)
            if sizeLeft > 0 {
                memset(ioData[i].mData! + Int(sizeCopied), 0, sizeLeft)
            }
        }
    }

    private func audioPlayerDidRenderSample(sampleTimestamp _: AudioTimeStamp) {
        if let currentRender {
            let currentPreparePosition = currentRender.timestamp + currentRender.duration * Int64(currentRenderReadOffset) / Int64(currentRender.numberOfSamples)
            if currentPreparePosition > 0 {
                var time = currentRender.timebase.cmtime(for: currentPreparePosition)
                if outputLatency != 0 {
                    /// AVSampleBufferAudioRenderer不需要处理outputLatency。其他音频输出的都要处理。
                    /// 没有蓝牙的话，outputLatency为0.015，有蓝牙耳机的话为0.176
                    time = time - CMTime(seconds: outputLatency, preferredTimescale: time.timescale)
                }
                renderSource?.setAudio(time: time, position: currentRender.position)
            }
        }
    }
}

extension AVAudioEngine {
    func connect(nodes: [AVAudioNode], format: AVAudioFormat?) {
        if nodes.count < 2 {
            return
        }
        for i in 0 ..< nodes.count - 1 {
            connect(nodes[i], to: nodes[i + 1], format: format)
        }
    }
}
