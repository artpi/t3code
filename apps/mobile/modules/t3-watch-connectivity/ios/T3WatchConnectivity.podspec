Pod::Spec.new do |s|
  s.name = 'T3WatchConnectivity'
  s.version = '1.0.0'
  s.summary = 'Optional T3 Code Watch companion transport.'
  s.description = 'Receives Watch requests before the JavaScript runtime is ready.'
  s.author = 'T3 Code contributors'
  s.homepage = 'https://github.com/pingdotgg/t3code'
  s.platforms = { :ios => '18.0' }
  s.source = { :path => '.' }
  s.static_framework = true
  s.dependency 'ExpoModulesCore'
  s.frameworks = 'WatchConnectivity'
  s.source_files = '**/*.swift'
end
