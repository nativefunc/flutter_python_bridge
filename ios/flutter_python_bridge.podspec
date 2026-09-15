Pod::Spec.new do |s|
  s.name             = 'flutter_python_bridge'
  s.version          = '0.3.0'
  s.summary          = 'Embedded CPython runtime for Flutter.'
  s.description      = 'Embedded CPython runtime for Flutter on Android and iOS.'
  s.homepage         = 'https://github.com/nativefunc/flutter_python_bridge'
  s.license          = { :file => '../LICENSE' }
  s.author           = 'NativeFunc'
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.{h,m,swift}'
  s.public_header_files = 'Classes/**/*.h'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.swift_version = '5.0'
  s.vendored_frameworks = 'Frameworks/*.xcframework', 'Frameworks/*.framework'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_ALLOW_NON_MODULAR_INCLUDES_IN_FRAMEWORK_MODULES' => 'YES'
  }
end
