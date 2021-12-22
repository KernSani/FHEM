# $Id: 98_NSPC.pm 000002 2020-01-04 23:22:15Z KernSani $
##############################################################################
#
#      98_NSPC.pm
#     An FHEM Perl module that supports parental control for Nintendo Switch
#
#     Copyright by KernSani
#
#     Fhem is free software: you can redistribute it and/or modify
#     it under the terms of the GNU General Public License as published by
#     the Free Software Foundation, either version 2 of the License, or
#     (at your option) any later version.
#
#     Fhem is distributed in the hope that it will be useful,
#     but WITHOUT ANY WARRANTY; without even the implied warranty of
#     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#     GNU General Public License for more details.
#
#     You should have received a copy of the GNU General Public License
#     along with fhem.  If not, see <http://www.gnu.org/licenses/>.
#
##############################################################################
#     Changelog:
##############################################################################
##############################################################################
#     Todo:
#
#
##############################################################################

package main;

use strict;
use warnings;
use HttpUtils;
use Data::Dumper;
use FHEM::Meta;
use B qw(svref_2object);

my $missingModul = "";
eval "use Digest::SHA qw(sha256);1;" or $missingModul .= "Digest::SHA ";
eval "use MIME::Base64::URLSafe;1;"  or $missingModul .= "MIME::Base64::URLSafe ";

my @wdays = ( "su", "mo", "tu", "we", "th", "fr", "sa" );

#####################################
sub NSPC_Initialize($) {
    my ($hash) = @_;

    $hash->{DefFn}   = "NSPC_Define";
    $hash->{UndefFn} = "NSPC_Undefine";
    $hash->{GetFn}   = "NSPC_Get";
    $hash->{SetFn}   = "NSPC_Set";
    $hash->{AttrFn}  = "NSPC_Attr";

    my @nspc_attr = ( "ns_interval " . "ns_summaryDays " );
    $hash->{AttrList} = join( " ", @nspc_attr ) . " " . $readingFnAttributes;
    return FHEM::Meta::InitMod( __FILE__, $hash );
}

#####################################
sub NSPC_Define($@) {
    my ( $hash, $def ) = @_;

    return $@ unless ( FHEM::Meta::SetInternals($hash) );

    my @a = split( "[ \t][ \t]*", $def );
    my $usage = "syntax: define <name> NSPC";
    return "Cannot define device. Please install perl modules $missingModul."
        if ($missingModul);

    my ( $name, $type ) = @a;
    if ( int(@a) != 2 ) {
        return $usage;
    }

    Log3 $name, 3, "[$name] NSPC defined $name";

    $hash->{NAME} = $name;

    # some default values
    CommandAttr( undef, $name . " ns_interval 3600" )
        if ( AttrVal( $name, "ns_interval", "" ) eq "" );
    CommandAttr( undef, $name . " stateFormat pc_alarm playtimeToday/maxtimeToday bedtimeToday" )
        if ( AttrVal( $name, "stateFormat", "" ) eq "" );
    CommandAttr( undef, $name . " ns_summaryDays 7" )
        if ( AttrVal( $name, "ns_summaryDays", "" ) eq "" );

    #start timer
    if ( AttrNum( $name, "ns_interval", 0 ) > 0 && $init_done ) {
        my $next = int( gettimeofday() ) + 1;
        InternalTimer( $next, 'NSPC_ProcessTimer', $hash, 0 );
    }
}
###################################
sub NSPC_Undefine($$) {
    my ( $hash, $name ) = @_;
    RemoveInternalTimer($hash);
    return undef;
}
###################################
sub NSPC_Notify($$) {
    my ( $hash, $dev ) = @_;
    my $name = $hash->{NAME};               # own name / hash
    my $events = deviceEvents( $dev, 1 );

    return ""
        if ( IsDisabled($name) );           # Return without any further action if the module is disabled
    return if ( !grep( m/^INITIALIZED|REREADCFG$/, @{$events} ) );

    RemoveInternalTimer($hash);
    my $next = int( gettimeofday() ) + 1;
    InternalTimer( $next, 'NSPC_ProcessTimer', $hash, 0 );
}
###################################
sub NSPC_Set($@) {
    my ( $hash, $name, $cmd, @args ) = @_;

    return "\"set $name\" needs at least one argument" unless ( defined($cmd) );
    my $ret
        = "Unknown argument $cmd, choose one of alarmState:on,off timerMode:daily,individually bedtimeDay maxtimeDay restrictionMode:alarm,stop addMaxtimeToday addBedtimeToday";

    if ( $cmd eq "alarmState" ) {
        if ( $args[0] =~ /on|off/ ) {
            NSPC_setAlarmSetting( $hash, $args[0] );
        }
        else {
            return $ret;
        }
    }
    elsif ( $cmd eq "addMaxtimeToday" ) {
        NSPC_addMaxtimeToday( $hash, $args[0] );
    }
    elsif ( $cmd eq "addBedtimeToday" ) {
        NSPC_addBedtimeToday( $hash, $args[0] );
    }
    elsif ( $cmd eq "timerMode" || $cmd eq "bedtimeDay" || $cmd eq "maxtimeDay" || $cmd eq "restrictionMode" ) {
        NSPC_setPCSetting( $hash, $cmd, $args[0] );
    }
    else {
        return $ret;
    }
}

#####################################
sub NSPC_Get($@) {
    my ( $hash, @a ) = @_;
    my $name  = $hash->{NAME};
    my $ret   = "";
    my $usage = 'Unknown argument $a[1], choose one of query:noArg getUrl:noArg sessionCode reloadUser:noArg';

    return "\"get $name\" needs at least one argument" unless ( defined( $a[1] ) );

    if ( $a[1] eq "query" ) {
        return NSPC_query($hash);
    }
    elsif ( $a[1] eq "getUrl" ) {
        return NSPC_getUrl($hash);
    }
    elsif ( $a[1] eq "sessionCode" ) {
        return NSPC_getSessionCode( $hash, $a[2] );
    }
    elsif ( $a[1] eq "reloadUser" ) {
        push @{ $hash->{helper}{cmdQueue} }, \&NSPC_getBearerToken;
        push @{ $hash->{helper}{cmdQueue} }, \&NSPC_getMe;
        NSPC_processCmdQueue($hash);
    }

    # return usage hint
    else {
        return $usage;
    }
    return undef;
}
#####################################
sub NSPC_processCmdQueue($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    return undef if ( !defined( $hash->{helper}{cmdQueue} ) );
    my $cmd = shift @{ $hash->{helper}{cmdQueue} };
    return undef unless ref($cmd) eq "CODE";
    my $cv = svref_2object($cmd);
    my $gv = $cv->GV;
    Log3 $name, 4, "[$name] Processing Queue: " . $gv->NAME;

    $cmd->($hash);
}
#####################################
sub NSPC_getSessionCode($$) {
    my ( $hash, $str ) = @_;
    my $name = $hash->{NAME};
    my ($token) = $str =~ /de=(.*)&/;

    my $param;
    $param->{header} = {

        #':authority'     => 'accounts.nintendo.com',
        #'Host'            => 'accounts.nintendo.com',
        #'content-length'  => '588',
        'content-type' => 'application/x-www-form-urlencoded',

        #'connection'      => 'keep-alive',
        'user-agent' =>
            'Mozilla/5.0 (iPhone; CPU iPhone OS 10_3_3 like Mac OS X) AppleWebKit/603.3.8 (KHTML, like Gecko) Mobile/14G60',
        'accept' => 'application/json',

        #'accept-language' => 'de-DE;q=1.0, en-DE;q=0.9',
        'accept-encoding' => 'gzip, deflate'
    };
    $param->{data} = {
        "client_id"                   => "54789befb391a838",
        "session_token_code_verifier" => "$hash->{AUTHCODE}",
        "session_token_code"          => "$token"
    };
    $param->{url}    = 'https://accounts.nintendo.com/connect/1.0.0/api/session_token';
    $param->{method} = "POST";
    Log3 $name, 5, "[$name] getSessionCode using token $token and verifier $hash->{AUTHCODE}";

    my ( $err, $data ) = HttpUtils_BlockingGet($param);

    Log3 $name, 5, "[$name] getSessionCode received $data";

    my $json = NSPC_safe_decode_json( $hash, $data );

    if ( $json->{error} ) {
        readingsBeginUpdate($hash);
        readingsBulkUpdate( $hash, "error",             $json->{error} );
        readingsBulkUpdate( $hash, "error_description", $json->{error_description} );
        readingsEndUpdate( $hash, 1 );
    }
    else {
        readingsBeginUpdate($hash);
        readingsBulkUpdate( $hash, "session_token", $json->{session_token} );
        readingsBulkUpdate( $hash, "code",          $json->{code} );
        readingsEndUpdate( $hash, 1 );
    }

    $hash->{SESSIONTOKEN} = $json->{session_token};
    Log3 $name, 5, "[$name] Extracted token $token token:";
    return undef;

}

#####################################
sub NSPC_getUrl($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    my $auth_state = urlsafe_b64encode( join( '', map { ( 'a' .. 'z', 'A' .. 'Z', 0 .. 9 )[ rand 62 ] } 0 .. 35 ) );
    my $auth_code_verifier
        = urlsafe_b64encode( join( '', map { ( 'a' .. 'z', 'A' .. 'Z', 0 .. 9 )[ rand 62 ] } 0 .. 31 ) );
    $auth_code_verifier =~ s/=//;
    $hash->{AUTHCODE} = $auth_code_verifier;

    my $auth_code_challenge = urlsafe_b64encode( sha256($auth_code_verifier) );
    $auth_code_challenge =~ s/\=//;
    Log3 $name, 5, $auth_state . "---" . $auth_code_verifier . "---" . $auth_code_challenge;

    my $param;
    $param->{header} = {
        'Host'                      => 'accounts.nintendo.com',
        'Connection'                => 'keep-alive',
        'Cache-Control'             => 'max-age=0',
        'Upgrade-Insecure-Requests' => '1',
        'User-Agent' =>
            'Mozilla/5.0 (Linux; Android 7.1.2; Pixel Build/NJH47D; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/59.0.3071.125 Mobile Safari/537.36',
        'Accept'          => 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8n',
        'DNT'             => '1',
        'Accept-Encoding' => 'gzip, deflate, br'
    };

#   $param->{data} = {
#        'state'=>$auth_state,
#       'redirect_uri'=>'npf54789befb391a838://auth',
#       'client_id'=>'54789befb391a838',
#       'scope'=>'openid user user.mii moonUser:administration moonDevice:create moonOwnedDevice:administration moonParentalControlSetting moonParentalControlSetting:update moonParentalControlSettingState moonPairingState moonSmartDevice:administration moonDailySummary moonMonthlySummary',
#       'response_type'=>'session_token_code',
#       'session_token_code_challenge'=>$auth_code_challenge,
#       'session_token_code_challenge_method'=>'S256',
#       'theme'=>'login_form'
#   };
    my $query
        = '?state='
        . $auth_state
        . '&redirect_uri=npf54789befb391a838%3A%2F%2Fauth&client_id=54789befb391a838&'
        . 'scope=openid+user+user.mii+moonUser%3Aadministration+moonDevice%3Acreate+moonOwnedDevice%3Aadministration+moonParentalControlSetting+moonParentalControlSetting%3Aupdate+moonParentalControlSettingState+moonPairingState+moonSmartDevice%3Aadministration+moonDailySummary+moonMonthlySummary&'
        . 'response_type=session_token_code&session_token_code_challenge='
        . $auth_code_challenge
        . '&session_token_code_challenge_method=S256&theme=login_form';

    #$query = urlEncode($query);

    $param->{method} = "GET";
    $param->{url}    = 'https://accounts.nintendo.com/connect/1.0.0/authorize' . $query;
    Log3 $name, 5, "[$name] Generated URL is $param->{url}";

    # my ($err, $data) = HttpUtils_BlockingGet( $param);
    #Log3 $name, 5, $err." / ".$data;
    my $ret
        = "<html>"
        . "Copy & Paste the following URL into your browser:</br>"
        . $param->{url} . "</br>"
        . "Log in, right click the 'Use this account' button, copy the link address, and execute 'get $name sessionCode <copied link address>'";
    return $ret;
}

#####################################
sub NSPC_query($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    push @{ $hash->{helper}{cmdQueue} }, \&NSPC_getBearerToken;
    push @{ $hash->{helper}{cmdQueue} }, \&NSPC_getMe if ReadingsVal( $name, "account_id", "" ) eq "";
    push @{ $hash->{helper}{cmdQueue} }, \&NSPC_getDevices;
    push @{ $hash->{helper}{cmdQueue} }, \&NSPC_getDailySummary;
    push @{ $hash->{helper}{cmdQueue} }, \&NSPC_getPCSettings;

    NSPC_processCmdQueue($hash);

    #    NSPC_getBearerToken($hash);
    #    NSPC_getMe($hash) if ReadingsVal( $name, "account_id", "" ) eq "";
    #    NSPC_getDevices($hash);    #if ReadingsVal($name,"device_id","") eq ""; --> always needed for alarm setting
    #    Log3 $name, 5, "[$name] Get Summary";
    #    NSPC_getDailySummary($hash);
    #    NSPC_getPCSettings($hash);

    #NSPC_getState($hash);
    return undef;
}
#####################################
# sub NSPC_getState($) {
#     my ($hash) = @_;
#     my $name = $hash->{NAME};

#     my $state   = ReadingsVal( $name, "pc_alarm", "" );
#     my $r1      = NSPC_getTodayReadingName("");
#     my $maxtime = "";
#     my $endtime = "";
#     if ( ReadingsVal( $name, "pc_00_all_timer", "" ) eq "EACH_DAY_OF_THE_WEEK" ) {
#         $maxtime = ReadingsVal( $name, $r1 . "maxtime", "-" );
#         $endtime = ReadingsVal( $name, $r1 . "bedtime", "-" );
#     }
#     else {
#         $maxtime = ReadingsVal( $name, $r1 . "pc_00_all_maxtime", "-" );
#         $endtime = ReadingsVal( $name, $r1 . "pc_00_all_bedtime", "-" );
#     }
#     $state .= " " . ReadingsVal( $name, "00_time", 0 ) . " / " . $maxtime . " " . $endtime;
#     readingsBeginUpdate($hash);
#     readingsBulkUpdate( $hash, "state", $state );
#     readingsEndUpdate( $hash, 1 );

# }

#####################################
sub NSPC_getBearerToken($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    my $session_token = ReadingsVal( $name, "session_token", "" );
    $hash->{SESSIONTOKEN} = $session_token;
    Log3 $name, 5, "[$name] GetBearer - Session Token is $session_token";
    my $param;
    $param->{header} = {
        'authority'       => 'accounts.nintendo.com',
        'Content-Type'    => 'application/json; charset=utf-8',
        'Connection'      => 'keep-alive',
        'User-Agent'      => 'OnlineLounge/1.0.4 NASDKAPI iOS',
        'Accept'          => 'application/json',
        'Accept-Language' => 'en-US',
        'Accept-Encoding' => 'gzip, deflate'
    };
    $param->{data}
        = '{ "client_id":"54789befb391a838", "grant_type":"urn:ietf:params:oauth:grant-type:jwt-bearer-session-token", "session_token":"'
        . $session_token . '" }';

    $param->{url}    = 'https://accounts.nintendo.com/connect/1.0.0/api/token';
    $param->{method} = "POST";
    my ( $err, $data ) = HttpUtils_BlockingGet($param);

    my $json = NSPC_safe_decode_json( $hash, $data );
    return unless $json;
    if ( $json->{error} ) {
        readingsBeginUpdate($hash);
        readingsBulkUpdate( $hash, "error",             $json->{error} );
        readingsBulkUpdate( $hash, "error_description", $json->{error_description} );
        readingsEndUpdate( $hash, 1 );
    }
    else {
        readingsBeginUpdate($hash);
        readingsBulkUpdate( $hash, "access_token", $json->{access_token} );
        readingsBulkUpdate( $hash, "id_token",     $json->{id_token} );
        readingsEndUpdate( $hash, 1 );
    }
    NSPC_processCmdQueue($hash);
    return undef;

}
#####################################
sub NSPC_getMe($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    my $access_token = ReadingsVal( $name, "access_token", "" );
    Log3 $name, 5, "[$name] GetMe - Access Token is $access_token";
    my $param;
    $param->{header} = {
        'authorization'   => 'Bearer ' . $access_token,
        'Host'            => 'api.accounts.nintendo.com',
        'Connection'      => 'keep-alive',
        'User-Agent'      => 'OnlineLounge/1.0.4 NASDKAPI iOS',
        'Accept'          => 'application/json',
        'Accept-Language' => 'en-US',
        'Accept-Encoding' => 'gzip, deflate'
    };
    $param->{url}    = 'https://api.accounts.nintendo.com/2.0.0/users/me';
    $param->{method} = "GET";
    my ( $err, $data ) = HttpUtils_BlockingGet($param);
    Log3 $name, 5, "[$name] GetMe - received $data";

    my $json = NSPC_safe_decode_json( $hash, $data );
    return unless $json;
    Log3 $name, 5, "[$name] GetMe - JSON is: " . Dumper($json);
    if ( $json->{errorCode} ) {
        readingsBeginUpdate($hash);
        readingsBulkUpdate( $hash, "error",             $json->{errorCode} );
        readingsBulkUpdate( $hash, "error_description", $json->{detail} );
        readingsEndUpdate( $hash, 1 );
    }
    else {
        readingsBeginUpdate($hash);
        readingsBulkUpdate( $hash, "account_id",   $json->{id} );
        readingsBulkUpdate( $hash, "account_nick", $json->{nickname} );
        readingsEndUpdate( $hash, 1 );
    }
    NSPC_processCmdQueue($hash);
    return "<html>" . $data . "</html>";

}
#####################################
sub NSPC_getDevices($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    my $account_id   = ReadingsVal( $name, "account_id",   "" );
    my $access_token = ReadingsVal( $name, "access_token", "" );

    my $header = {
        'authorization'               => 'Bearer ' . $access_token,
        'User-Agent'                  => 'moon_ios/1.10.0 (com.nintendo.znma; build:281; iOS 13.3.0) Alamofire/4.8.2',
        'Accept'                      => 'application/json',
        'Accept-Language'             => 'en-US',
        'Accept-Encoding'             => 'gzip, deflate',
        'authority'                   => 'api-lp1.pctl.srv.nintendo.net',
        'x-moon-app-id'               => 'com.nintendo.znma',
        'x-moon-app-internal-version' => '281',
        'x-moon-app-display-version'  => '1.10.0',
        'x-moon-app-id'               => 'com.nintendo.znma',
        'x-moon-os'                   => 'IOS',
        'x-moon-os-version'           => '13.3',
        'x-moon-model'                => 'iPhone10,6',
        'x-moon-timezone'             => 'Europe/Berlin',
        'x-moon-os-language'          => 'de-DE',
        'x-moon-app-language'         => 'de-DE'
    };
    my $param = {
        header   => $header,
        url      => 'https://api-lp1.pctl.srv.nintendo.net/moon/v1/users/' . $account_id . '/devices',
        method   => "GET",
        hash     => $hash,
        callback => \&NSPC_getDevicesCallback
    };

    #my ( $err, $data ) = HttpUtils_BlockingGet($param);
    Log3 $name, 5, "[$name] GetDevice - Starting Blocking Call";
    HttpUtils_NonblockingGet($param);
}

#####################################
sub NSPC_getDevicesCallback($) {
    my ( $param, $err, $data ) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};

    Log3 $name, 5, "[$name] GetDevice - received $data";

    my $json = NSPC_safe_decode_json( $hash, $data );
    return unless $json;
    Log3 $name, 5, "[$name] GetDevice - JSON is: " . Dumper($json);
    if ( $json->{errorCode} ) {
        readingsBeginUpdate($hash);
        readingsBulkUpdate( $hash, "error",             $json->{errorCode} );
        readingsBulkUpdate( $hash, "error_description", $json->{detail} );
        readingsEndUpdate( $hash, 1 );
    }
    elsif ( defined( $json->{items} ) ) {
        my @devices = @{ $json->{items} };    #currently only one device
        readingsBeginUpdate($hash);
        readingsBulkUpdate( $hash, "device_id",   $devices[0]->{deviceId} );
        readingsBulkUpdate( $hash, "device_name", $devices[0]->{label} );
        my $device = $devices[0]->{device};
        readingsBulkUpdate( $hash, "device_code", $device->{synchronizedUnlockCode} );

        my %alarm = ( "VISIBLE" => "Alarms active", "INVISIBLE" => "Alarms disabled for today" );

        readingsBulkUpdate( $hash, "pc_alarm", $alarm{ $device->{alarmSetting}{visibility} } );
        readingsEndUpdate( $hash, 1 );
    }
    NSPC_processCmdQueue($hash);

    #NSPC_getState($hash);
    return "<html>" . $data . "</html>";

}
#####################################
sub NSPC_getAlarmSetting($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    my $device_id    = ReadingsVal( $name, "device_id",    "" );
    my $access_token = ReadingsVal( $name, "access_token", "" );

    my $param;
    $param->{header} = {
        'authorization'               => 'Bearer ' . $access_token,
        'User-Agent'                  => 'moon_ios/1.10.0 (com.nintendo.znma; build:281; iOS 13.3.0) Alamofire/4.8.2',
        'Accept'                      => 'application/json',
        'Accept-Language'             => 'en-US',
        'Accept-Encoding'             => 'gzip, deflate',
        'authority'                   => 'api-lp1.pctl.srv.nintendo.net',
        'x-moon-app-id'               => 'com.nintendo.znma',
        'x-moon-app-internal-version' => '281',
        'x-moon-app-display-version'  => '1.10.0',
        'x-moon-app-id'               => 'com.nintendo.znma',
        'x-moon-os'                   => 'IOS',
        'x-moon-os-version'           => '13.3',
        'x-moon-model'                => 'iPhone10,6',
        'x-moon-timezone'             => 'Europe/Berlin',
        'x-moon-os-language'          => 'de-DE',
        'x-moon-app-language'         => 'de-DE'
    };
    $param->{url}    = 'https://api-lp1.pctl.srv.nintendo.net/moon/v1/devices/' . $device_id . '/alarm_setting_state';
    $param->{method} = "Get";
    my ( $err, $data ) = HttpUtils_BlockingGet($param);
    Log3 $name, 5, "[$name] Get AlarmSetting - received $data";

    my $json = NSPC_safe_decode_json( $hash, $data );
    return unless $json;
    Log3 $name, 5, "[$name] Get AlarmSetting - JSON is: " . Dumper($json);
    if ( $json->{errorCode} ) {
        readingsBeginUpdate($hash);
        readingsBulkUpdate( $hash, "error",             $json->{errorCode} );
        readingsBulkUpdate( $hash, "error_description", $json->{detail} );
        readingsEndUpdate( $hash, 1 );
    }
    else {
        readingsBeginUpdate($hash);
        readingsBulkUpdate( $hash, "pc_alarm_setState", $json->{status} );
        readingsEndUpdate( $hash, 1 );
    }
    return $json->{errorCode} || $json->{status};

    #NSPC_getState($hash);
}
#####################################
sub NSPC_setAlarmSetting($$) {
    my ( $hash, $state ) = @_;
    my $name = $hash->{NAME};

    #token refresh
    NSPC_getBearerToken($hash);

    #set state
    my $device_id    = ReadingsVal( $name, "device_id",    "" );
    my $access_token = ReadingsVal( $name, "access_token", "" );

    my %alarmStates = ( "on" => "TO_VISIBLE", "off" => "TO_INVISIBLE" );

    my $param;
    $param->{header} = {
        'authorization'               => 'Bearer ' . $access_token,
        'content-type'                => '  application/json',
        'User-Agent'                  => 'moon_ios/1.10.0 (com.nintendo.znma; build:281; iOS 13.3.0) Alamofire/4.8.2',
        'Accept'                      => 'application/json',
        'Accept-Language'             => 'en-US',
        'Accept-Encoding'             => 'gzip, deflate',
        'authority'                   => 'api-lp1.pctl.srv.nintendo.net',
        'x-moon-app-id'               => 'com.nintendo.znma',
        'x-moon-app-internal-version' => '281',
        'x-moon-app-display-version'  => '1.10.0',
        'x-moon-app-id'               => 'com.nintendo.znma',
        'x-moon-os'                   => 'IOS',
        'x-moon-os-version'           => '13.3',
        'x-moon-model'                => 'iPhone10,6',
        'x-moon-timezone'             => 'Europe/Berlin',
        'x-moon-os-language'          => 'de-DE',
        'x-moon-app-language'         => 'de-DE'
    };
    $param->{url}    = 'https://api-lp1.pctl.srv.nintendo.net/moon/v1/devices/' . $device_id . '/alarm_setting_state';
    $param->{method} = "POST";
    $param->{data}   = '{"status": "' . $alarmStates{$state} . '"}';

    my ( $err, $data ) = HttpUtils_BlockingGet($param);
    Log3 $name, 5, "[$name] Get AlarmSetting - received $data";

    my $json = NSPC_safe_decode_json( $hash, $data );
    return unless $json;
    Log3 $name, 5, "[$name] Get AlarmSetting - JSON is: " . Dumper($json);
    if ( $json->{errorCode} ) {
        readingsBeginUpdate($hash);
        readingsBulkUpdate( $hash, "error",             $json->{errorCode} );
        readingsBulkUpdate( $hash, "error_description", $json->{detail} );
        readingsEndUpdate( $hash, 1 );
    }
    else {
        readingsBeginUpdate($hash);
        readingsBulkUpdate( $hash, "pc_alarm_setState", $json->{status} );
        readingsEndUpdate( $hash, 1 );
    }

    # get state
    $data = NSPC_getAlarmSetting($hash);

    #refresh device settings
    NSPC_getDevices($hash) if $data eq $alarmStates{$state};

    return undef;

}
#####################################
sub NSPC_getTodayReadingName($) {
    my ($rname) = @_;
    my ( $sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst ) = localtime(time);
    my $weekday = $wdays[$wday];
    if ($wday == 0) {$wday = 7};
    my $r1 = "pc_" . sprintf( "%02d", $wday ) . "_" . $weekday . "_" . $rname;


    return $r1;

}
#####################################
sub NSPC_addMaxtimeToday($$) {
    my ( $hash, $arg ) = @_;
    my $name = $hash->{NAME};
    my ( $sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst ) = localtime(time);
    my $weekday = $wdays[$wday];

    my $r1      = NSPC_getTodayReadingName("maxtime");
    my $ct      = ReadingsVal( $name, $r1, 0 );
    my $addTime = $arg + $ct;
    my $set     = $weekday . "|" . $addTime;

    NSPC_setPCSetting( $hash, "maxtimeDay", $set );
}
#####################################
sub NSPC_addBedtimeToday($$) {
    my ( $hash, $arg ) = @_;
    my $name = $hash->{NAME};
    my ( $sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst ) = localtime(time);
    my $weekday = $wdays[$wday];

    my $r1 = NSPC_getTodayReadingName("bedtime");
    Log3 $name, 5, "[$name] Reading name is $r1";
    my $ct = ReadingsVal( $name, $r1, 0 );
    my ( $h, $m ) = split( ":", $ct );
    my $minutes = $h * 60 + $m + $arg;
    $h = int( $minutes / 60 );
    $m = $minutes % 60;
    my $addTime = $h . ":" . $m;
    my $set     = $weekday . "|" . $addTime;
    Log3 $name, 4, "[$name] Setting bedtime: $set";
    NSPC_setPCSetting( $hash, "bedtimeDay", $set );
}

#####################################
sub NSPC_setPCSetting($$$) {
    my ( $hash, $cmd, $arg ) = @_;
    my $name = $hash->{NAME};

    $hash->{helper}{cmd}           = $cmd;
    $hash->{helper}{arg}           = $arg;
    $hash->{helper}{getPCSettings} = "setFunction";

    push @{ $hash->{helper}{cmdQueue} }, \&NSPC_getBearerToken;
    push @{ $hash->{helper}{cmdQueue} }, \&NSPC_getPCSettings;
    NSPC_processCmdQueue($hash);

    #token refresh
    #NSPC_getBearerToken($hash);

    #get current setting
    #NSPC_getPCSettings($hash);
}

#####################################
sub NSPC_setPCSettingsCallback($$$) {
    my ( $param, $err, $json ) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};

    my $cmd = $hash->{helper}{cmd};
    my $arg = $hash->{helper}{arg};
    delete $hash->{helper}{getPCSettings};

    my $setting = NSPC_safe_decode_json( $hash, $json );
    return unless $json;
    my %modes  = ( "daily" => "DAILY", "individually" => "EACH_DAY_OF_THE_WEEK" );
    my %rmodes = ( "alarm" => "ALARM", "stop"         => "FORCED_TERMINATION" );

    my %days = (
        "mo"  => "monday",
        "tu"  => "tuesday",
        "we"  => "wednesday",
        "th"  => "thursday",
        "fr"  => "friday",
        "sa"  => "saturday",
        "su"  => "sunday",
        "all" => "all"
    );

    if ( $cmd eq "timerMode" ) {
        $setting->{playTimerRegulations}{timerMode} = $modes{$arg};
    }
    elsif ( $cmd eq "restrictionMode" ) {
        $setting->{playTimerRegulations}{restrictionMode} = $rmodes{$arg};
    }

    elsif ( $cmd eq "bedtimeDay" ) {
        my @sets = split( ",", $arg );
        foreach my $set (@sets) {
            my ( $key, $value ) = split( /\|/, $set );
            Log3 $name, 5, "[$name] Setting days - $key : $value";
            if ( !$days{$key} ) {
                return "Please use mo,tu,we,th,fr,sa,su or all for weekdays";
            }
            my ( $h, $m ) = split( /:/, $value );
            return "Value for hours has  to be between 16 and 23" if $h < 16 or $h > 23;
            if ( $m > 45 or $m < 0 or $m % 15 != 0 ) {
                return "Value for minutes must be between 0 and 45 in 15 minutes steps";
            }
            Log3 $name, 5, "[$name] Setting bedtime for $key to $h : $m";
            if ( $key eq "all" ) {
                $setting->{playTimerRegulations}{dailyRegulations}{bedtime}{endingTime}{hour}   = $h;
                $setting->{playTimerRegulations}{dailyRegulations}{bedtime}{endingTime}{minute} = $m;
            }
            else {
                $setting->{playTimerRegulations}{eachDayOfTheWeekRegulations}{ $days{$key} }{bedtime}{endingTime}{hour}
                    = $h;
                $setting->{playTimerRegulations}{eachDayOfTheWeekRegulations}{ $days{$key} }{bedtime}{endingTime}
                    {minute} = $m;
            }
        }

    }
    elsif ( $cmd eq "maxtimeDay" ) {
        my @sets = split( ",", $arg );
        foreach my $set (@sets) {
            my ( $key, $value ) = split( /\|/, $set );
            Log3 $name, 5, "[$name] Setting maxtime - $key($days{$key}) : $value";
            if ( !$days{$key} ) {
                return "Please use mo,tu,we,th,fr,sa,su or all for weekdays";
            }
            if ( $value ne "null" and ( $value > 360 or $value < 0 or $value % 15 != 0 ) ) {
                return "Value for maxtime must be between 0 and 360 in 15 minutes steps (or 'null')";
            }
            if ( $key eq "all" ) {
                $setting->{playTimerRegulations}{dailyRegulations}{timeToPlayInOneDay}{limitTime} = $value;
            }
            else {
                $setting->{playTimerRegulations}{eachDayOfTheWeekRegulations}{ $days{$key} }{timeToPlayInOneDay}
                    {limitTime} = $value;
            }
        }

    }
    else {
        return undef;
    }

    delete $setting->{createdAt};
    delete $setting->{updatedAt};
    delete $setting->{deviceId};
    delete $setting->{etag};
    delete $setting->{whitelistedApplications};

    $json = encode_json($setting);

    #set state
    my $device_id    = ReadingsVal( $name, "device_id",    "" );
    my $access_token = ReadingsVal( $name, "access_token", "" );

    my $header = {
        'authorization'               => 'Bearer ' . $access_token,
        'content-type'                => '  application/json',
        'User-Agent'                  => 'moon_ios/1.10.0 (com.nintendo.znma; build:281; iOS 13.3.0) Alamofire/4.8.2',
        'Accept'                      => 'application/json',
        'Accept-Language'             => 'en-US',
        'Accept-Encoding'             => 'gzip, deflate',
        'authority'                   => 'api-lp1.pctl.srv.nintendo.net',
        'x-moon-app-id'               => 'com.nintendo.znma',
        'x-moon-app-internal-version' => '281',
        'x-moon-app-display-version'  => '1.10.0',
        'x-moon-app-id'               => 'com.nintendo.znma',
        'x-moon-os'                   => 'IOS',
        'x-moon-os-version'           => '13.3',
        'x-moon-model'                => 'iPhone10,6',
        'x-moon-timezone'             => 'Europe/Berlin',
        'x-moon-os-language'          => 'de-DE',
        'x-moon-app-language'         => 'de-DE'
    };
    $param = {
        header   => $header,
        url      => 'https://api-lp1.pctl.srv.nintendo.net/moon/v1/devices/' . $device_id . '/parental_control_setting',
        method   => "POST",
        data     => $json,
        hash     => $hash,
        callback => \&NSPC_getPCSettingsCallback
    };

    HttpUtils_NonblockingGet($param);

}

#####################################
sub NSPC_getDailySummary($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    my $device_id    = ReadingsVal( $name, "device_id",    "" );
    my $access_token = ReadingsVal( $name, "access_token", "" );

    my $header = {
        'authorization'               => 'Bearer ' . $access_token,
        'User-Agent'                  => 'moon_ios/1.10.0 (com.nintendo.znma; build:281; iOS 13.3.0) Alamofire/4.8.2',
        'Accept'                      => 'application/json',
        'Accept-Language'             => 'en-US',
        'Accept-Encoding'             => 'gzip, deflate',
        'authority'                   => 'api-lp1.pctl.srv.nintendo.net',
        'x-moon-app-id'               => 'com.nintendo.znma',
        'x-moon-app-internal-version' => '281',
        'x-moon-app-display-version'  => '1.10.0',
        'x-moon-app-id'               => 'com.nintendo.znma',
        'x-moon-os'                   => 'IOS',
        'x-moon-os-version'           => '13.3',
        'x-moon-model'                => 'iPhone10,6',
        'x-moon-timezone'             => 'Europe/Berlin',
        'x-moon-os-language'          => 'de-DE',
        'x-moon-app-language'         => 'de-DE'
    };

    my $param = {
        header   => $header,
        url      => 'https://api-lp1.pctl.srv.nintendo.net/moon/v1/devices/' . $device_id . '/daily_summaries',
        method   => "GET",
        hash     => $hash,
        callback => \&NSPC_getDailySummaryCallback
    };
    HttpUtils_NonblockingGet($param);
}
############################
sub NSPC_getDailySummaryCallback($) {
    my ( $param, $err, $data ) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};

    Log3 $name, 5, "[$name] Get DailySummary - received $data";

    my $json = NSPC_safe_decode_json( $hash, $data );
    return unless $json;
    Log3 $name, 5, "[$name] Get DailySummary - JSON is: " . Dumper($json);
    if ( $json->{errorCode} ) {
        readingsBeginUpdate($hash);
        readingsBulkUpdate( $hash, "error",             $json->{errorCode} );
        readingsBulkUpdate( $hash, "error_description", $json->{detail} );
        readingsEndUpdate( $hash, 1 );
    }
    else {
        my @days = @{ $json->{items} };
        readingsBeginUpdate($hash);
        readingsBulkUpdate( $hash, "playtimeToday", $days[0]->{playingTime} / 60 );
        my $summaryDays = AttrNum( $name, "ns_summaryDays", 7 );
        my $i = 0;
        while ( $i < $summaryDays && $days[$i] ) {
            readingsBulkUpdate( $hash, "0" . $i . "_date", $days[$i]->{date} );
            readingsBulkUpdate( $hash, "0" . $i . "_time", $days[$i]->{playingTime} / 60 );
            $i++;
        }
        readingsEndUpdate( $hash, 1 );
    }
    NSPC_processCmdQueue($hash);
    return undef;
}
#####################################
sub NSPC_getPCSettings($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    my $device_id    = ReadingsVal( $name, "device_id",    "" );
    my $access_token = ReadingsVal( $name, "access_token", "" );
    my $callback;
    if ( $hash->{helper}{getPCSettings} && $hash->{helper}{getPCSettings} eq "setFunction" ) {
        $callback = \&NSPC_setPCSettingsCallback;
    }
    else {
        $callback = \&NSPC_getPCSettingsCallback;
    }

    my $header = {
        'authorization'               => 'Bearer ' . $access_token,
        'User-Agent'                  => 'moon_ios/1.10.0 (com.nintendo.znma; build:281; iOS 13.3.0) Alamofire/4.8.2',
        'Accept'                      => 'application/json',
        'Accept-Language'             => 'en-US',
        'Accept-Encoding'             => 'gzip, deflate',
        'authority'                   => 'api-lp1.pctl.srv.nintendo.net',
        'x-moon-app-id'               => 'com.nintendo.znma',
        'x-moon-app-internal-version' => '281',
        'x-moon-app-display-version'  => '1.10.0',
        'x-moon-app-id'               => 'com.nintendo.znma',
        'x-moon-os'                   => 'IOS',
        'x-moon-os-version'           => '13.3',
        'x-moon-model'                => 'iPhone10,6',
        'x-moon-timezone'             => 'Europe/Berlin',
        'x-moon-os-language'          => 'de-DE',
        'x-moon-app-language'         => 'de-DE'
    };
    my $param = {
        header   => $header,
        url      => 'https://api-lp1.pctl.srv.nintendo.net/moon/v1/devices/' . $device_id . '/parental_control_setting',
        method   => "GET",
        hash     => $hash,
        callback => $callback
    };
    HttpUtils_NonblockingGet($param);
}
#####################################
sub NSPC_getPCSettingsCallback($) {
    my ( $param, $err, $data ) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};

    NSPC_PCSettings_parse( $hash, $data );
    NSPC_processCmdQueue($hash);

    # my $json = NSPC_safe_decode_json( $hash, $data );
    # return $json;
}
#####################################
sub NSPC_PCSettings_parse($$) {
    my ( $hash, $data ) = @_;
    my $name = $hash->{NAME};

    Log3 $name, 5, "[$name] Get PCSettings - received $data";

    # some replacements to avoid weird stuff fom json decode
    $data =~ s/true/"true"/g;
    $data =~ s/false/"false"/g;
    $data =~ s/null/"null"/g;
    my $json = NSPC_safe_decode_json( $hash, $data );
    return unless $json;

    Log3 $name, 5, "[$name] Get PCSettings - JSON is: " . Dumper($json);
    if ( $json->{errorCode} ) {
        readingsBeginUpdate($hash);
        readingsBulkUpdate( $hash, "error",             $json->{errorCode} );
        readingsBulkUpdate( $hash, "error_description", $json->{detail} );
        readingsEndUpdate( $hash, 1 );
    }
    else {
        my $reg  = $json->{playTimerRegulations};
        my $day  = $reg->{dailyRegulations};
        my $each = $reg->{eachDayOfTheWeekRegulations};

        readingsBeginUpdate($hash);
        readingsBulkUpdate( $hash, "pc_00_all_mode",  $reg->{restrictionMode} );
        readingsBulkUpdate( $hash, "pc_00_all_timer", $reg->{timerMode} );
        my $bedtime;
        my $maxtime;

        if ( $day->{bedtime}{enabled} eq "true" ) {
            $bedtime = $day->{bedtime}{endingTime}{hour} . ":" . sprintf( "%02d", $day->{bedtime}{endingTime}{minute} );
        }
        else {
            $bedtime = $day->{bedtime}{endingTime};
        }
        readingsBulkUpdate( $hash, "pc_00_all_bedtime",         $bedtime );
        readingsBulkUpdate( $hash, "pc_00_all_bedtime_enabled", $day->{bedtime}{enabled} );
        readingsBulkUpdate( $hash, "pc_00_all_maxtime",         $day->{timeToPlayInOneDay}{limitTime} );
        readingsBulkUpdate( $hash, "pc_00_all_maxtime_enabled", $day->{timeToPlayInOneDay}{enabled} );

        if ( $reg->{timerMode} ne "EACH_DAY_OF_THE_WEEK" ) {
            readingsBulkUpdate( $hash, "bedtimeToday", $bedtime );
            readingsBulkUpdate( $hash, "maxtimeToday", $day->{timeToPlayInOneDay}{limitTime} );
        }

        my ( $sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst ) = localtime(time);
        my $weekday = $wdays[$wday];

        my %weekdays = (
            "monday"    => "01_mo",
            "tuesday"   => "02_tu",
            "wednesday" => "03_we",
            "thursday"  => "04_th",
            "friday"    => "05_fr",
            "saturday"  => "06_sa",
            "sunday"    => "07_su"
        );
        for my $w ( keys %weekdays ) {
            if ( $each->{$w}{bedtime}{enabled} eq "true" ) {
                $bedtime = $each->{$w}{bedtime}{endingTime}{hour} . ":"
                    . sprintf( "%02d", $each->{$w}{bedtime}{endingTime}{minute} );
            }
            else {
                $bedtime = $each->{$w}{bedtime}{endingTime};
            }
            readingsBulkUpdate( $hash, "pc_" . $weekdays{$w} . "_bedtime",         $bedtime );
            readingsBulkUpdate( $hash, "pc_" . $weekdays{$w} . "_bedtime_enabled", $each->{$w}{bedtime}{enabled} );
            readingsBulkUpdate(
                $hash,
                "pc_" . $weekdays{$w} . "_maxtime_enabled",
                $each->{$w}{timeToPlayInOneDay}{enabled}
            );
            readingsBulkUpdate( $hash, "pc_" . $weekdays{$w} . "_maxtime", $each->{$w}{timeToPlayInOneDay}{limitTime} );
            Log3 $name, 4, "$weekdays{$w} --> $weekday";
            if ( $weekdays{$w} =~ /$weekday/ && $reg->{timerMode} eq "EACH_DAY_OF_THE_WEEK" ) {
                readingsBulkUpdate( $hash, "bedtimeToday", $bedtime );
                readingsBulkUpdate( $hash, "maxtimeToday", $each->{$w}{timeToPlayInOneDay}{limitTime} );
            }
        }
    }

    readingsEndUpdate( $hash, 1 );

    #NSPC_getState($hash);
}

#####################################
sub NSPC_ProcessTimer($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    NSPC_query($hash);

    my $now = int( gettimeofday() );
    my $interval = AttrNum( $name, "ns_interval", 0 );
    if ( $interval > 0 ) {
        my $next = $now + $interval;
        InternalTimer( $next, 'NSPC_ProcessTimer', $hash, 0 );
    }

}
###################################
sub NSPC_Attr($) {

    my ( $cmd, $name, $aName, $aVal ) = @_;
    my $hash = $defs{$name};
    if ( $cmd eq "set" ) {
        if ( $aName eq "ns_interval" ) {
            if ( int( $aVal > 0 ) ) {
                my $next = int( gettimeofday() ) + int($aVal);
                InternalTimer( $next, 'NSPC_ProcessTimer', $hash, 0 );
            }
            else {
                RemoveInternalTimer($hash);
            }
        }
        elsif ( $aName eq "ns_summaryDays" ) {
            if ( int( $aVal < 1 or $aVal > 30 ) ) {
                return "Summary can be retrieved for 1 to 31 days";
            }
        }
    }
    elsif ( $cmd eq "del" ) {
        if ( $aName eq "ns_interval" ) {
            RemoveInternalTimer($hash);
        }
    }
}

sub NSPC_safe_decode_json($$) {
    my ( $hash, $data ) = @_;
    my $name = $hash->{NAME};

    my $json = undef;
    eval {
        $json = decode_json($data);
        1;
    } or do {
        my $error = $@ || 'Unknown failure';
        Log3 $name, 1, "[$name] - Received invalid JSON: $error";

    };
    return $json;
}
1;

=pod
=item helper
=item summary Gets timetable information from DSBMobile
=item summary_DE Liest Vertretungspläne von DSBMobile


=begin html

<a name="DSBMobile"></a>
<div>
    <ul>
        DSBMobile reads and displays timetable change information from DSBMobile App, which is used at some schools in Germany (at least)<br><br>
        <a name="DSBMobileDefine"></a>
        <b>Define</b>
        <ul>
            DSBMobile uses several perl modules which have to be installed in advance:
            <ul>
                <li>IO::Compress::Gzip</li>
                <li>IO::Uncompress::Gunzip</li>
                <li>MIME::Base64</li>
                <li>HTML::TableExtract</li>
                DSBMobile will be defined without Parameters.
                <br><br>
                <code>define &lt;devicename&gt; DSBMobile</code><br><br>
                <br><br>
            </ul>
        </ul>
        <a name="DSBMobileGet"></a>
        <b>Get</b>
        <ul>
            <li><a name="timetable">Retrieves the current timetable changes and postings</li>
        </ul>
        <a name="DSBMobileReadings"></a>
        <b>Readings</b>
        <ul>
            Following readings are created:
            <ul>
                <li>columnNames: Readingnames generated dynamically from substitution table column headers</li>
                <li>lastCheck: Date/Time of the last successful check for new data</li>
                <li>lastSync: Date/Time of the last run where data was actually synchronized (not only checked)</li>
                <li>lastTTUpdate: Date/Time of the last update of the timetable data on the DSBMobile server</li>
                <li>error: contains the error message of the last error that occured while fetching data</li>
                <li>state: "ok" if last run was successful, "error" if not.</li>
            </ul>
            For each posting and change in the timetable the following readings are generated
            <ul>
                <li>i#_date: Date of the posting</li>
                <li>i#_title: Title of the posting</li>
                <li>i#_url: Link to the posting</li>
                <li>ti#_sdate: Date of the "Info of the day"</li>
                <li>ti#_topic: Title of the "Info of the day"</li>
                <li>ti#_text: Content of the "Info of the day"</li>
                <li>tt#_xxxx: Dynamically generated reading for each column of the substitution table</li>
            </ul>
        </ul>
        <a name="DSBMobileAttr"></a>
        <b>Attributes</b>
        <ul>
            <ul>
                <li><a name="dsb_user">dsb_user</a>: The user to log in to DSBMobile</li>
                <li><a name="dsb_password">dsb_password</a>: The password to log in to DSBMobile</li>
                <li><a name="dsb_class">dsb_class</a>: The grade to filter for. Can be a regex, e.g. 5a|8b or 6.*c.</li>
                <li><a name="dsb_classReading">dsb_classReading</a>: Has to be set if the column containing the class(es) is not named "Klasse(n)", i.e. the genarated reading is not "Klasse_n_"</li>
                <li><a name="dsb_interval">dsb_interval</a>: Interval in seconds to pull DSBMobile, value of 0 means disabled</li>
                <li><a name="dsb_outputFormat">dsb_outputFormat</a>: can be used to format the output of the weblink. Takes the readingnames enclosed in % as variables, e.g. <code>%Klasse_n_%</code></li>
            </ul>
        </ul>
        DSBMobile additionally provides two functions to display the information in weblinks:
        <ul>
            <li>DSBMobile_simpleHTML($name ["dsb","showInfoOfTheDay"]): Shows the timetable changes, if the second optional parameter is "1", the Info of the Day will be displayed additionally.
                Example <code>defmod dsb_web weblink htmlCode {DSBMobile_simpleHTML("dsb",1)}</code>
            </li>
            <li>DSBMobile_infoHTML($name): Shows the postings with links to the Details.
                Example <code>defmod dsb_infoweb weblink htmlCode {DSBMobile_infoHTML("dsb")}</code>
            </li>
        </ul>
    </ul>
</div>

=end html
=begin html_DE

<a name="DSBMobile"></a>
<div>
    <ul>
        DSBMobile liest die Vertretungspläne der DSBMobile App, die (zumindest) an einigen Schulen in Deutschland verwendet wird<br><br>
        <a name="DSBMobileDefine"></a>
    </ul>
    <b>Define</b>
    <ul>
        DSBMobile verwendet einige Perl-Module, die vorab installiert werden müssen:
        <ul>
            <li>IO::Compress::Gzip</li>
            <li>IO::Uncompress::Gunzip</li>
            <li>MIME::Base64</li>
            <li>HTML::TableExtract</li>
            DSBMobile wird ohne Parameter definiert.
            <br><br>
            <code>define &lt;devicename&gt; DSBMobile</code><br><br>
            <br><br>
        </ul>
        <a name="DSBMobileGet"></a>
        <b>Get</b>
        <ul>
            <ul>
                <li><a name="timetable">Empfängt die aktuellen Vertretungsplan- und Aushang-Informationen</li>
            </ul>
        </ul>
        <a name="DSBMobileReadings"></a>
        <b>Readings</b>
        <ul>
            Die folgenden Readings werden erstellt:
            <ul>
                <li>columnNames: Readingnamen, die dynamisch aus den Spaltenüberschriften des Vertretungsplans generiert werden</li>
                <li>lastCheck: Datum/Uhrzeit der letzten erfolgreichen Überprüfung auf neue Daten</li>
                <li>lastSync: Datum/Uhrzeit der letzten erfolgreichen Synchronisierung neuer Daten(nicht nur Überprüfung)</li>
                <li>lastTTUpdate: Datum/Uhrzeit der letztenAktualisierung auf dem DSBMobile Server</li>
                <li>error: enthält die letzte Fehlermeldung, die bei der Datensynchronisierung aufgetreten ist</li>
                <li>state: "ok" sofern der letzte Abruf erfolgreich war, "error" wenn nicht.</li>
            </ul>
            Für jeden Aushang bzw. jede Vertretung werden folgende Readings erstellt
            <ul>
                <li>i#_date: Datum des Aushangs</li>
                <li>i#_title: Titel des Aushangs</li>
                <li>i#_url: Link zum Aushang</li>
                <li>ti#_sdate: Datum der "Info des Tages"</li>
                <li>ti#_topic: Titel der "Info des Tages"</li>
                <li>ti#_text: Inhalt der "Info des Tages"</li>
                <li>tt#_xxxxDynamisch generierte Readings für jede Spalte des Vertretungsplanes</li>
            </ul>
        </ul>
        <a name="DSBMobileAttr"></a>
        <b>Attributes</b>
        <ul>
            <ul>
                <li><a name="dsb_user">dsb_user</a>: Der User für die DSBMobile-Anmeldung</li>
                <li><a name="dsb_password">dsb_password</a>: Das Passwort für die DSBMobile-Anmeldung</li>
                <li><a name="dsb_class">dsb_class</a>: Die Klasse nach der gefiltert werden soll. Kann eine Regex sein, z.B. 5a|8b or 6.*c.</li>
                <li><a name="dsb_classReading">dsb_classReading</a>: Muss gesetzt werden, wenn die Spalte mit der Klasse nicht "Klasse(n)" heisst, d.h. das generierte reading nicht "Klasse_n_" lautet</li>
                <li><a name="dsb_interval">dsb_interval</a>: Intervall in Sekunden in dem Daten von DSBMobile abgerufen werden, ein Wert von 0 bedeuted disabled</li>
                <li><a name="dsb_outputFormat">dsb_outputFormat</a>: Kann benutzt werden, um den Output des weblinks zu formatieren. Die Readingnamen von % umschlossen können als Variablen verwendet werden, z.B. <code>%Klasse_n_%</code></li>
            </ul>
        </ul>
        DSBMobile bietet zusätzlich zwei Funktionen, um die Informationen in weblinks darzustellen:
        <ul>
            <li>DSBMobile_simpleHTML($name ["dsb",showInfoOfTheDay]): Zeigt den Vertretungsplan, wenn der zweite optionale Parameter auf "1" gesetzt wird, wird die Info des Tages zusätzlich mit angezeigt.
                Beispiel <code>defmod dsb_web weblink htmlCode {DSBMobile_simpleHTML("dsb",1)}</code>
            </li>
            <li>DSBMobile_infoHTML($name): Zeigt die Aushänge mit Links zu den Details.
                Beispiel <code>defmod dsb_infoweb weblink htmlCode {DSBMobile_infoHTML("dsb")}</code>
            </li>
        </ul>
    </ul>
</div>
=end html_DE

=for :application/json;q=META.json 98_NSPC.pm
    {
      "abstract": "Parental Control for Nintendo Switch",
      "description": "DSBMobile reads and displays timetable change information from DSBMobile App, which is used at some schools in Germany (at least).",
      "x_lang": {
        "de": {
          "abstract": "Liest Vertretungspläne von DSBMobile",
          "description": "DSBMobile liest Vertretungspläne von DSBMobile und zeigt sie an. DSBMobile wird (zumindest) an einigen Schulen in Deutschland verwendet"
        }
      },
      "license":"gpl_2",
      "version": "v0.0.4",
      "x_release_date": "2020-10-01",
      "release_status": "testing",
      "author": [
        "Oli Merten aka KernSani"
      ],
      "x_fhem_maintainer": [
        "KernSani"
      ],
      "keywords": [
        "DSBMobile",
        "Schule",
        "Vertretungsplan",
        "Vertretung",
        "Stundenplan",
        "school",
        "timetable",
        "substitutions"
      ],
      "prereqs": {
        "runtime": {
          "requires": {
            "FHEM": 5.00918623,
            "FHEM::Meta": 0.001006,
            "HttpUtils": 0,
            "JSON": 0,
            "perl": 5.014,
            "IO::Compress::Gzip": 0,
            "IO::Uncompress::Gunzip": 0,
            "MIME::Base64": 0,
            "HTML::TableExtract": 0,
            "HTML::TreeBuilder": 0
          },
          "recommends": {
          },
          "suggests": {
          }
        }
      },
      "x_copyright": {
          "mailto": "oli.merten@gmail.com",
          "title": "Oli Merten"
      },
      "x_support_community": {
          "title": "Support Thread",
          "web": "https://forum.fhem.de/index.php/topic,107104.msg1011580.html"
       },
      "x_support_status": "supported"
    }

=end :application/json;q=META.json

=cut
