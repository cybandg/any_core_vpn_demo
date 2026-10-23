Pod::Spec.new do |s|
  s.name             = 'any_core_vpn'
  s.version          = '0.0.1'
  s.summary          = 'macOS cores for sing-box / Xray VPN plugin'
  s.description      = 'Bundles sing-box and Xray CLI cores with a privileged supervisor.'
  s.homepage         = 'https://github.com/blamurai/any_core_vpn'
  s.license          = { :type => 'MIT' }
  s.author           = { 'blamurai' => 'dev@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'any_core_vpn/Sources/any_core_vpn/**/*.{h,m,swift}'
  s.resource_bundles = {
    'any_core_vpn_privacy' => [
      'any_core_vpn/Sources/any_core_vpn/PrivacyInfo.xcprivacy'
    ]
    'any_core_vpn_cores' => [
      'cores/sing-box',
      'cores/xray',
      'cores/helper',
      'cores/geoip.dat',
      'cores/geosite.dat',
      'cores/manifest.json'
    ]
  }
  s.dependency 'FlutterMacOS'
  s.platform         = :osx, '12.0'
  s.osx.deployment_target = '12.0'
  s.swift_version    = '5.0'
end