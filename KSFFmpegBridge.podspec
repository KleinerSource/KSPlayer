Pod::Spec.new do |s|
  s.name = 'KSFFmpegBridge'
  s.version = '1.0.0'
  s.summary = 'Swift macro bridge for official FFmpeg public headers'
  s.homepage = 'https://github.com/KleinerSource/KSPlayer'
  s.authors = { 'kintan' => 'kingslay@icloud.com' }
  s.license = { :type => 'GPL-3.0', :file => 'LICENSE' }
  s.source = { :git => 'https://github.com/KleinerSource/KSPlayer.git' }
  s.ios.deployment_target = '16.0'
  s.static_framework = true
  s.source_files = 'Sources/KSFFmpegBridge/**/*.{h,c}'
  s.public_header_files = 'Sources/KSFFmpegBridge/include/*.h'
  s.dependency 'FFmpegKitNext', '9.0.2'
end
