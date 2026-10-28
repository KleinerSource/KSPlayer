Pod::Spec.new do |s|
    s.name             = 'KSPlayer'
    s.version          = '1.2.0'
    s.summary          = 'Video Player Using Swift, based on AVPlayer,FFmpeg'

    s.description      = <<-DESC
    Video Player Using Swift, based on ffmpeg, support for the horizontal screen, vertical screen, the upper and lower slide to adjust the volume, the screen brightness, or so slide to adjust the playback progress.
    DESC

    s.homepage         = 'https://github.com/KleinerSource/KSPlayer'
    s.authors = { 'kintan' => 'kingslay@icloud.com' }
    s.license          = { :type => 'GPL-3.0', :file => 'LICENSE' }
    s.source           = { :git => 'https://github.com/KleinerSource/KSPlayer.git', :tag => s.version.to_s }

    s.ios.deployment_target = '16.0'
    s.osx.deployment_target = '10.15'
    # s.watchos.deployment_target = '2.0'
    s.tvos.deployment_target = '13.0'
    s.static_framework = true
    s.swift_version = '5.9'
    s.source_files = 'Sources/KSPlayer/**/*.{swift,metal}'
    s.frameworks = 'AudioToolbox', 'AVFoundation', 'VideoToolbox'
    s.ios.frameworks = 'UIKit'
    s.tvos.frameworks = 'UIKit'
    s.osx.frameworks = 'AppKit'
    s.weak_framework = 'MetalKit'
    s.resource_bundles = {
        'KSPlayer_KSPlayer' => ['Sources/KSPlayer/Metal/*.metal']
    }
    s.dependency 'DisplayCriteria'
    s.dependency 'KSFFmpegBridge'
    s.dependency 'FFmpegKitNext', '9.0.2'
    s.test_spec 'Tests' do |test_spec|
        test_spec.source_files = 'Tests/KSPlayerTests/*.swift'
        test_spec.resources = 'Tests/KSPlayerTests/Resources/*'
    end    
end
