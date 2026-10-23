import 'dart:math';

import 'package:any_core_vpn/meta_service_configs/specific_configs/selected_vpn_core_config.dart';
import 'package:any_core_vpn/vpn_service/config_builders/core_config_builder.dart';
import 'package:any_core_vpn/vpn_service/link_parsers/link_parser.dart';

const String PLUGIN_DEVELOPER_CONTACT_INFO = "tg: @CybandG_16 (https://t.me/CybandG_16), email: blamurai.official@gmail.com";

sealed class VpnServiceException implements Exception{
    String get message => _message??"specific message is not provided";
    final String? _message;

    const VpnServiceException({String? defaultMessage}) : _message = defaultMessage;

    @override
  String toString() {
    return "$runtimeType: $message";
  }
}

final class GeneralVpnServiceException extends VpnServiceException{
  const GeneralVpnServiceException({required super.defaultMessage});
}

//region link parser exceptions
final class NotSupportedVpnLinkTypeException extends VpnServiceException{
  @override
  String get message => "${super.message}" 
  "Link prefix provided: $originalLinkPrefix.\nActual core supports only: "
  "${ProtocolTypes.values.where((e) => e != ProtocolTypes.notSupported).join(", ")} types";

  final String originalLinkPrefix;

  NotSupportedVpnLinkTypeException({required String link, super.defaultMessage = "Provided wrong or unsupported vpn link."}) 
    : originalLinkPrefix = link.substring(0, min(12, link.length));
}

final class InvalidVpnLinkTypeException extends VpnServiceException{
  @override
  String get message => super.message + ("Link prefix provided: $originalLinkPrefix. "
  "${reason == null? '' : ' Reason: $reason'}");

  final String originalLinkPrefix;
  final String? reason;

  InvalidVpnLinkTypeException({required String link, required this.reason, super.defaultMessage = "Provided invalid vpn link."}) 
    : originalLinkPrefix = link.substring(0,  min(12, link.length));
}
//endregion link parser exceptions

//region freemium restrictions
final class UnsupportedInDemoVersionException extends VpnServiceException{
  @override
    String get message => super.message + ("The feature ($featureDescriprion)"
    "is not available in this plugin free(demo) version! But it's available in full version.\n"
    "Contact me: [$PLUGIN_DEVELOPER_CONTACT_INFO] to get access or consultation or costom modification or vpn client development!");

    final String featureDescriprion;

    const UnsupportedInDemoVersionException({required this.featureDescriprion});
}

//endregion

//region vpn config builder exceptions
final class UnsupportedProtocolException extends VpnServiceException{
    @override
    String get message => super.message + ("You provided ${providedProtocolType.name} link type, "
    "however $sellectedVpnCore not supports it because: ${_reasonMessage()}");

    final ProtocolTypes providedProtocolType;
    final VpnCore sellectedVpnCore;
    final ProtocolSupportStatus supportStatus;
    
    const UnsupportedProtocolException({
      required this.supportStatus, 
      required this.providedProtocolType, 
      required this.sellectedVpnCore, 
      super.defaultMessage = "Provided unsupported protocol type."
      });

    String _reasonMessage() =>
      switch(supportStatus){
        ProtocolSupportStatus.supported =>
          "LOL, idk why it even showed... This is declared as supported... Seems like something bad happened... "
          "report me if you cought this error: look at pub.dev page, there are my contacts.",
        ProtocolSupportStatus.unsupported =>
          "It seems like this protocol is complitely unsupported by sellected core, try to change core, "
          "or if it would not help, then it's a platform issue...",
        ProtocolSupportStatus.yetUnsupported =>
          "It seems like this protocol is potentially supported by sellected core, but I didn't realise it yet.",
        ProtocolSupportStatus.supportedInPaidVersion =>
           "You try to use free version of the plugin. "
           "Contact me: [$PLUGIN_DEVELOPER_CONTACT_INFO] to get access to full version or consultation or costom modification or vpn client development!"
      };
    
}
//endregion

//region permissions exceptions
final class PermissionDeniedException extends VpnServiceException{
  @override
    String get message => super.message + ("Permission denied: User could decline permission for establishing vpn connection");

  const PermissionDeniedException({super.defaultMessage = "VPN Permission denied. "});
}
//endregion

//region key storage
class VpnKeyStorageException extends VpnServiceException {
  const VpnKeyStorageException({required super.defaultMessage});
}

class UnknownVpnKeyTypeException extends VpnKeyStorageException {
  final String keyType;
  @override
  String get message => 'No serializer registered for key type "$keyType"';

  const UnknownVpnKeyTypeException({required this.keyType, super.defaultMessage = "Provided wrong or unsupported vpn link."});
}

class VpnKeyAlreadyExistsException extends VpnKeyStorageException {
  final String id;

  @override
  String get message => 'Key with id "$id" already exists';

  const VpnKeyAlreadyExistsException({required this.id, super.defaultMessage = "Key already exists"});
}

class VpnKeyNotFoundException extends VpnKeyStorageException {
  final String id;

  @override
  String get message => 'Key with id "$id" not found';

  const VpnKeyNotFoundException({required this.id, super.defaultMessage = "Key not found"});
}
//endregion