# $Id: 98_homezone.pm 18522 2019-02-07 22:06:35Z KernSani $
##############################################################################
#
#     98_homezone.pm
#     An FHEM Perl module that implements a zone concept in FHEM
#     inspired by https://smartisant.com/research/presence/index.php
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
#       0.0.22 (2021-04-20):      Bugfix        -   Fixed duplicating "associatedWith" entries
#       0.0.21 (2021-04-19):      Bugfix        -   Fixed various issues with "hz_dayTimes"-Attribute
#                                 Maintenance   -   Adjusted/Improved commandref
#       0.0.20 (2021-04-18):      Bugfix        -   Fixed $empty Bug
#       0.0.19 (2021-04-17):      Bugfix        -   Changed some loglevels 
#                                 Maintenance   -   text-field long for all attributes (where it makes sense)
#       0.0.18 (2021-04-16):      Feature       -   added commandref
#                                 Feature       -   allow daytime-dependent commands      
#       0.0.17:	Feature         -   added doAlways attribute
#	 	0.0.16:	Feature         -   "Probably associated with" will be populated
#                               -   Fixed Bug with absence event
#       0.0.15: Maintenance     -   Code cleanup
#       0.0.14: Bugfix          -   Unnecessary log messages (Execution failed) removed
#               Bugfix          -   Fixed a bug in attribute validation (occupanyEvent)
#               Feature         -   Configure that "asleep" roommates trigger "present" (hz_sleepRoommates)
#       0.0.13: Bugfix          -   Fixed another bug with diableOnlyCmds
#               Bugfix          -   Fixed a perl warning (uninitialized value in numeric)
#               Feature         -   Added possibility to set inactive for <seconds>
#       0.0.12: Bugfix          -   Fixed buggy diableOnlyCmds
#               Feature         -   $name allowed in perl commands
#               Feature         -   new reading lastChild
#       0.0.11: Bugfix          -   in boxMode incorrectly triggered presence from adjacent zone
#               Feature         -   added diableOnlyCmds Attribute
#       0.0.10: Bugfix          -   Multiline perl
#               Feature         -   Optimized boxMode
#       0.0.09: Bugfix          -   Adjacent zone stuck at occupied 100 in some cases
#               Bugfix          -   boxMode was stopped by timer in adjacent zone
#               Feature         -   Allow Perl in Commands (incl. big textfield to edit)
#               Bugfix          -   adjacent or children attributes could get lost at reload
#       0.0.08: Feature         -   Added disabled-Attributes and set active/inactive
#               Feature         -   Added boxMode
#       0.0.07: Bugfix          -   Fixed a minor bug with lastLumi reading not updating properly
#               Feature         -   Support for multiple doors (wasp-in-a-box)
#       0.0.06: Bugfix          -   Luminance devices not found on startup
#               Bugfix          -   Lumithreshold not properly determined
#               Maintainance    -   Improved Logging
#               Bugfix          -   Parent devices not updating properly
#               Feature         -   Added absenceEvent
#       0.0.05: Maintenance     -   Code cleanup
#               Maintenance     -   Attribute validation and userattr cleanup
#               Bugfix          -   Fixed bug when "close" comes after "occupancy"
#               Feature         -   Some additional readings
#       0.0.04: Feature         -   Added state-dependant commands
#               Feature         -   Added luminance functions
#       0.0.03: Feature         -   Added basic version of daytime-dependant decay value
#       0.0.02: Feature         -   Added "children" attribute
#               Feature         -   List of regexes for Event Attributes
#       0.0.01: initial version
#
##############################################################################

package main;

use strict;
use warnings;
use List::MoreUtils;

#use Data::Dumper;

my $version = "0.0.22";

# some constants
use constant {
    LOG_CRITICAL => 0,
    LOG_ERROR    => 1,
    LOG_WARNING  => 2,
    LOG_SEND     => 3,
    LOG_RECEIVE  => 4,
    LOG_DEBUG    => 5,
};
my $EMPTY = q{};
my $SPACE = q{ };
my $COMMA = q{,};

###################################
sub homezone_Initialize {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    # Module specific attributes
    my @homezone_attr
        = (   "hz_openEvent:textField-long"
            . " hz_closedEvent:textField-long"
            . " hz_occupancyEvent:textField-long"
            . " hz_absenceEvent:textField-long"
            . " hz_luminanceReading:textField-long"
            . " hz_lumiThreshold"
            . " hz_decay"
            . " hz_adjacent:textField-long"
            . " hz_state:textField-long"
            . " hz_dayTimes:textField-long"
            . " hz_multiDoor"
            . " hz_children:textField-long"
            . " hz_disableOnlyCmds:0,1"
            . " disable:0,1"
            . " disabledForIntervals"
            . " hz_sleepRoommates"
            . " hz_boxMode:0,1"
            . " hz_doAlways:0,1" );

    $hash->{SetFn}    = "homezone_Set";
    $hash->{DefFn}    = "homezone_Define";
    $hash->{UndefFn}  = "homezone_Undefine";
    $hash->{NotifyFn} = "homezone_Notify";
    $hash->{AttrFn}   = "homezone_Attr";
    $hash->{AttrList} = join( $SPACE, @homezone_attr ) . $SPACE . $readingFnAttributes;
    return;
}

###################################
sub homezone_Define {

    my ( $hash, $def ) = @_;
    my @a = split( /[ \t][ \t]*/xsm, $def );

    my $usage = "syntax: define <name> homezone";

    my ( $name, $type ) = @a;
    if ( int(@a) != 2 ) {
        return $usage;
    }

    $hash->{VERSION} = $version;
    $hash->{NAME}    = $name;

    # set default values for some attributes
    if ( AttrVal( $name, "hz_state", $EMPTY ) eq $EMPTY ) {
        CommandAttr( undef, $name . " hz_state 100:present 50:likely 1:unlikely 0:absent" );
    }
    if ( AttrVal( $name, "devStateIcon", $EMPTY ) eq $EMPTY ) {
        CommandAttr( undef,
            $name
                . " devStateIcon present:user_available\@green likely:user_available\@lightgreen unlikely:user_unknown\@yellow absent:user_away"
        );
    }

    my $dt = "05:00|morning 10:00|day 14:00|afternoon 18:00|evening 23:00|night";
    my @hm = devspec2array("TYPE=HOMEMODE");
    Log3 ($name, LOG_DEBUG, "[homezone - $name]: Homemode detected - ".Dumper(@hm)  );
    if ( $hm[0] ) {
        $dt = AttrVal( $hm[0], "HomeDaytimes", $EMPTY );
        Log3 ($name, LOG_DEBUG, "[homezone - $name]: Daytimes detected - $dt");
    }
    if ( AttrVal( $name, "hz_dayTimes", $EMPTY ) eq $EMPTY ) {
        CommandAttr( undef, $name . " hz_dayTimes $dt" );
    }

    return;
}
###################################
sub homezone_Undefine {
    my ( $hash, $name ) = @_;

    RemoveInternalTimer($hash);
    return;
}
###################################
sub homezone_Notify {
    my ( $hash, $dhash ) = @_;
    my $name = $hash->{NAME};    # own name / hash
    my $dev  = $dhash->{NAME};

    # Return without any further action if the module is disabled
    if ( IsDisabled($name) && AttrVal( $name, "hz_disableOnlyCmds", 0 ) == 0 ) {
        return;
    }

    my $events = deviceEvents( $dhash, 1 );

    # Check if children report new state
    my @children = split( /,/xsm, AttrVal( $name, "hz_children", "NA" ) );
    if ( grep( /$dev/xsm, @children ) && grep( /occupied/xsm, @{$events} ) ) {
        Log3 ($name, LOG_DEBUG, "[homezone - $name]: occupied event of child detected");
        my $max = 0;
        my $lastChild;
        foreach my $child (@children) {
            if ( ReadingsNum( $child, "occupied", 0 ) > $max ) {
                $max = ReadingsNum( $child, "occupied", 0 );
                $lastChild = $child;
            }
        }
        homezone_setOcc( $hash, $max, $lastChild );
        return;
    }

    # Check for occupied event in adjacent zones
    if ( AttrVal( $name, "hz_boxMode", 0 ) > 0 ) {
        my @zones = split( $COMMA, AttrVal( $name, "hz_adjacent", "NA" ) );
        if ( grep( /$dev/, @zones ) && grep( /occupied/, @{$events} ) ) {
            my $r = ReadingsVal( $dev, "lastZone", $EMPTY );
            Log3 $name, 5, "[homezone - $name]: occupied event of adjacent room $dev detected ($r)";
            if ( $r ne "timer" && ReadingsVal( $name, "occupied", 0 ) == 100 ) {

                #homezone_setOpen( $hash, undef );
                homezone_setOcc( $hash, 99, $dev );
            }
            return undef;
        }
    }

    # check for roommates asleep
    my @rm = split( $COMMA, AttrVal( $name, "hz_sleepRoommates", "NA" ) );

    if ( grep( /$dev/, @rm ) && grep( /state:.asleep/, @{$events} ) ) {
        Log3 $name, 5, "[homezone - $name]: roommate $dev asleep detected" . Dumper($events);
        homezone_setOcc( $hash, 100, $dev );
    }
    if ( grep( /$dev/, @rm ) && !( grep( /state:.asleep/, @{$events} ) ) ) {
        Log3 $name, 5, "[homezone - $name]: roommate $dev not asleep anymore";
        my $sleepers = @rm;
        my $i        = 0;
        foreach my $rr (@rm) {
            last if ( ReadingsVal( $rr, "state", $EMPTY ) eq "asleep" );
            $i++;
        }
        homezone_setOcc( $hash, 99, $dev ) if ( ReadingsNum( $name, "occupied", 0 ) == 100 && $i == $sleepers );
    }

    # Check open/close/occupancy Events

    # multiple doors
    my @mOpen;
    my $oE = AttrVal( $name, "hz_openEvent", $EMPTY );
    if ( $oE ne $EMPTY ) {
        @mOpen = split( $SPACE, $oE );
    }

    $hash->{HELPER}{doors} = scalar @mOpen;

    my @mClose;
    my $oC = AttrVal( $name, "hz_closedEvent", $EMPTY );
    if ( $oC ne $EMPTY ) {
        @mClose = split( $SPACE, $oC );
    }

    my @occ = split( $COMMA, AttrVal( $name, "hz_occupancyEvent", "NA:NA" ) );
    my @abs = split( $COMMA, AttrVal( $name, "hz_absenceEvent",   "NA:NA" ) );

    #return undef if ( !( $dev =~ /$openDev/ or $dev =~ /$closedDev/ or $dev =~ /$occDev/ ) );

    foreach my $event ( @{$events} ) {

        #Log3 $name, 5, "[homezone - $name]: processing event $event for Device $dev";
        my $i = 1;

        # open Event detected
        foreach my $mO (@mOpen) {
            my @open = split( $COMMA, $mO );

            foreach my $o (@open) {
                my ( $openDev, $openEv ) = split( ":", $o, 2 );
                last if !$openDev;
                if ( $dev =~ /$openDev/ && $event =~ /$openEv/ ) {
                    Log3 $name, 5, "[homezone - $name]: set open (event $openEv)";
                    homezone_setOpen( $hash, $i );
                    last;
                }
            }
            $i++;
        }
        $i = 1;

        # close Event detected
        foreach my $mO (@mClose) {
            my @close = split( $COMMA, $mO );

            foreach my $c (@close) {
                my ( $closedDev, $closedEv ) = split( ":", $c, 2 );
                if ( $dev =~ /$closedDev/ && $event =~ /$closedEv/ ) {
                    Log3 $name, 5, "[homezone - $name]: set closed (event $closedEv)";
                    homezone_setClosed( $hash, $i );
                    last;
                }
            }
            $i++;
        }

        # occupancy Event detected
        foreach my $o (@occ) {
            my ( $occDev, $occEv ) = split( ":", $o, 2 );
            if ( $dev =~ /$occDev/ && $event =~ /$occEv/ ) {
                Log3 $name, 5,
                    "[homezone - $name]: set occupancy in condition " . ReadingsVal( $name, "condition", $EMPTY );

                #homezone_setClosed( $hash, undef ) if AttrVal( $name, "hz_boxMode", 0 ) > 0;
                my $occ = 99;
                $occ = 100 if AttrVal( $name, "hz_boxMode", 0 ) > 0;
                my @rm = split( $COMMA, AttrVal( $name, "hz_sleepRoommates", "NA" ) );
                foreach my $rr (@rm) {
                    $occ = 100 if ReadingsVal( $rr, "state", $EMPTY ) eq "asleep";
                }
                homezone_setOcc( $hash, $occ );
                last;
            }
        }

        # absence Event detected
        foreach my $o (@abs) {
            my ( $absDev, $absEv ) = split( ":", $o, 2 );
            if ( $dev =~ /$absDev/ && $event =~ /$absEv/ ) {
                Log3 $name, 5,
                    "[homezone - $name]: set absence in condition " . ReadingsVal( $name, "condition", $EMPTY );
                homezone_setOcc( $hash, 0, "absence" );
                last;
            }
        }

    }

    return undef;
}

###################################
sub homezone_setOcc($$;$) {
    my ( $hash, $occ, $lastChild ) = @_;
    my $name = $hash->{NAME};

    $lastChild = "self" unless $lastChild;

    if ( ReadingsVal( $name, "condition", $EMPTY ) eq "closed" && $lastChild ne "timer" && $lastChild ne "absence" ) {
        $occ = 100;
    }

    # Determine state
    my $oldState = ReadingsVal( $name, "state", $EMPTY);
    my $stats = AttrVal( $name, "hz_state", $EMPTY );
    my $stat = $occ;
    if ( $stats ne $EMPTY ) {
        my %params = map { split /\:/xsm, $_ } ( split /\ /xsm, $stats );
        foreach my $param ( reverse sort { $a <=> $b } keys %params ) {
            if ( $occ >= $param ) {
                $stat = $params{$param};
                last;
            }
        }
    }

    # State changed --> Execute command
    my $dayTime = ReadingsVal($name, "lastDayTime", $EMPTY);
    my $do          = AttrVal( $name, "hz_doAlways", 0 );
    my $lumi        = 0;
    my $lumiReading = AttrVal( $name, "hz_luminanceReading", $EMPTY );
    if ( $lumiReading ne $EMPTY ) {
        my ( $d, $r ) = split( /:/xsm, $lumiReading );
        $lumi = ReadingsNum( $d, $r, 0 );
    }

    if ( ( ( $stat ne $oldState ) or ( $do == 1 && $lastChild ne "timer" ) ) && IsDisabled($name) == 0 ) {
        Log3( $name, LOG_DEBUG, "[homezone - $name]: state $stat (was $oldState), 'do' is $do" );
        my $cmd = AttrVal( $name, "hz_cmd_" . $stat, $EMPTY );
        $cmd =~ s/^(\n|[ \t])*//xsm;    # Strip space or \n at the begginning
        $cmd =~ s/[ \t]*$//xsm;

        #my $lumiThresholds = AttrVal( $name, "hz_lumiThreshold_" . $stat, $EMPTY );
        #my $lumiTh = ReadingsVal( $name, "hz_lumiThreshold", 0 );
        my ( $low, $high )
            = split( /:/xsm,
            AttrVal( $name, "hz_lumiThreshold_" . $stat, AttrVal( $name, "hz_lumiThreshold", "0:9999999999" ) ) );

        $low  = 0         if ( !$low );
        $high = 999999999 if ( !$high );
        Log3 ($name, 5, "[homezone - $name]: Luminance: $lumi Threshold: $low-$high");

        if ( $lumi >= $low and $lumi <= $high ) {
        	my @cmdqs = split(m/^/xsm, $cmd);
        	Log3 ($name, LOG_DEBUG, "[homezone - $name]: Commands extracted".Dumper(@cmdqs));
        	foreach my $cmdq (@cmdqs) {
        		my ($dt, $cm) = split(/:/xsm, $cmdq);
        		if (!$cm) {
        			$cmd = $dt;
        			Log3 ($name, LOG_DEBUG, "[homezone - $name]: Command set to $cmd");
        		}
        		else {
        			Log3 ($name, LOG_DEBUG, "[homezone - $name]: Daytime $dt, command $cm");
        			if ($dt eq $dayTime ) {
        				$cmd = $cm;
        				Log3 ($name, LOG_DEBUG, "[homezone - $name]: Command set to $cmd for $dayTime");
        				last;
        			}
        		}

        	}

            my %specials = ( "%name" => $name );
            $cmd = EvalSpecials( $cmd, %specials );
            if ( $cmd ne $EMPTY ) {

                Log3( $name, LOG_DEBUG, "[homezone - $name]: Executing command $cmd" );
                my $ret = AnalyzeCommandChain( undef, "$cmd" ) unless ( $cmd eq $EMPTY or $cmd =~ m/^\{.*}$/xsm );
                Log3 $name, 1, "[homezone - $name]: Command execution failed: $ret" if ($ret);
                $ret = AnalyzePerlCommand( undef, $cmd ) if ( $cmd =~ m/^\{.*}$/xsm );
                Log3 $name, 1, "[homezone - $name]: Perl execution failed: $ret" if ($ret);
            }
        }
    }

    # update adjacent zones
    my $adj = AttrVal( $name, "hz_adjacent", $EMPTY);
    if ( $adj ne $EMPTY && AttrVal( $name, "hz_boxMode", 0 ) == 0 ) {
        my @adj = split( /,/xsm, $adj );
        foreach $a (@adj) {
            my $aOcc = ReadingsNum( $a, "occupied", 0 );
            if ( $aOcc < $occ && $aOcc > 0 ) {
                AnalyzeCommandChain( undef, "set $a occupied $occ $name" );
            }
        }
    }
    my $leafChild = ReadingsVal( $lastChild, "lastChild", $EMPTY );
    if (    $leafChild eq $EMPTY
        and AttrVal( $name, "hz_children", "NA" ) ne "NA"
        and grep( $lastChild, split( /,/xsm, AttrVal( $name, "hz_children", "NA" ) ) ) )
    {
        $leafChild = $lastChild;
    }

    # update readings
    readingsBeginUpdate($hash);
    readingsBulkUpdate( $hash, "occupied",  $occ );
    readingsBulkUpdate( $hash, "state",     $stat );
    readingsBulkUpdate( $hash, "lastLumi",  $lumi ) if $lumiReading ne $EMPTY;
    readingsBulkUpdate( $hash, "lastZone",  $lastChild );
    readingsBulkUpdate( $hash, "lastChild", $leafChild ) if $leafChild ne $EMPTY;
    readingsEndUpdate( $hash, 1 );

    homezone_startTimer($hash);
    return;
}

###################################
sub homezone_setOpen($$) {
    my ( $hash, $door ) = @_;
    my $name = $hash->{NAME};
    my $cond = "open";
    if ( $hash->{HELPER}{doors} > 1 ) {
        readingsSingleUpdate( $hash, "door" . $door, "open", 0 );
        $cond = homezone_getDoorState($hash);
    }
    readingsSingleUpdate( $hash, "condition", $cond, 1 );
    if ( ReadingsNum( $name, "occupied", 0 ) == 100 ) {

        # check if adjacent was set to 100 by current zone
        my $adj = AttrVal( $name, "hz_adjacent", $EMPTY );
        if ( $adj ne $EMPTY && AttrVal( $name, "hz_boxMode", 0 ) == 0 ) {
            my @adj = split( $COMMA, $adj );
            foreach $a (@adj) {
                my $aOcc = ReadingsNum( $a, "occupied", 0 );
                my $alz = ReadingsVal( $a, "lastZone", $EMPTY );
                if ( $aOcc == 100 && $alz eq $name ) {
                    AnalyzeCommandChain( undef, "set $a open" );
                }
            }
        }
        homezone_setOcc( $hash, 99 );
    }

}

###################################
sub homezone_setClosed($$) {
    my ( $hash, $door ) = @_;
    my $name = $hash->{NAME};
    my $cond = "closed";
    if ( $hash->{HELPER}{doors} > 1 ) {
        readingsSingleUpdate( $hash, "door" . $door, "closed", 0 );
        $cond = homezone_getDoorState($hash);
    }
    readingsSingleUpdate( $hash, "condition", $cond, 1 );
}

###################################
sub homezone_Set($@) {
    my ( $hash, @a ) = @_;
    my $name = $hash->{NAME};

    return "no set value specified" if ( int(@a) < 2 );
    my $usage = "Unknown argument $a[1], choose one of active:noArg inactive occupied closed open";

    if ( $a[1] eq "inactive" ) {
        return "If an argument is given for $a[1] it has to be a number (in seconds)"
            if ( $a[2] && !( $a[2] =~ /^\d+$/ ) );
        RemoveInternalTimer( $hash, "homezone_ProcessTimer" );
        readingsSingleUpdate( $hash, "state", "inactive", 1 );
        if ( $a[2] ) {
            Log3 $name, 1, "Timer: $a[2]";
            my $tm = int( gettimeofday() ) + int( $a[2] );
            $hash->{HELPER}{ActiveTimer} = "inactive";
            InternalTimer( $tm, 'homezone_setActive', $hash, 0 );
        }
    }
    elsif ( $a[1] eq "active" ) {
        RemoveInternalTimer( $hash, "homezone_setActive" );
        if ( IsDisabled($name) ) {    #&& !AttrVal( $name, "disable", undef ) ) {
            readingsSingleUpdate( $hash, "state", "initialized", 1 );
        }
        else {
            return "[homezone - $name]: is already active";
        }
    }
    elsif ( $a[1] eq "occupied" ) {
        if ( $a[2] < 0 or $a[2] > 100 ) {
            return "Argument has to be between 0 and 100";
        }
        homezone_setOcc( $hash, $a[2], $a[3] )
            unless ( IsDisabled($name) && AttrVal( $name, "hz_disableOnlyCmds", 0 ) == 0 );
    }
    elsif ( $a[1] eq "open" ) {
        return "Argument has to be a number between 1 and $hash->{HELPER}{doors}"
            if (
            $hash->{HELPER}{doors}
            && (   $hash->{HELPER}{doors} > 1 and $a[2] < 1
                or $a[2] > $hash->{HELPER}{doors} )
            );
        homezone_setOpen( $hash, $a[2] ) unless ( IsDisabled($name) && AttrVal( $name, "hz_disableOnlyCmds", 0 ) == 0 );
    }
    elsif ( $a[1] eq "closed" ) {
        return "Argument has to be a number between 1 and $hash->{HELPER}{doors}"
            if $hash->{HELPER}{doors} > 1 and $a[2] < 1
            or $a[2] > $hash->{HELPER}{doors};
        homezone_setClosed( $hash, $a[2] )
            unless ( IsDisabled($name) && AttrVal( $name, "hz_disableOnlyCmds", 0 ) == 0 );
    }
    else {
        return $usage;
    }
    return undef;
}
###################################
sub homezone_setActive($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    if ( IsDisabled($name) ) {
        readingsSingleUpdate( $hash, "state", "initialized", 1 );
    }

}
###################################
sub homezone_startTimer($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    RemoveInternalTimer($hash);

    my $d = homezone_decay($hash);
    my $occupied = ReadingsVal( $name, "occupied", 0 );
    Log3 $name, 5, "[homezone - $name]: $occupied";
    if ( $d > 0 && $occupied < 100 && $occupied > 0 ) {
        my $step = $d / 10;
        my $now  = gettimeofday();
        $hash->{helper}{TIMER} = int($now) + $step;
        InternalTimer( $hash->{helper}{TIMER}, 'homezone_ProcessTimer', $hash, 0 );
    }

}

###################################
sub homezone_ProcessTimer($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my $occupied = ReadingsVal( $name, "occupied", 0 );
    my $pct = int( ( $occupied - 10 ) / 10 + 0.5 ) * 10;
    homezone_setOcc( $hash, $pct, "timer" );
}

###################################
sub homezone_Attr($) {

    my ( $cmd, $name, $aName, $aVal ) = @_;
    my $hash = $defs{$name};

    # . " hz_adjacent"
    # . " hz_children" );

    # $cmd can be "del" or "set"
    # $name is device name
    # aName and aVal are Attribute name and value
    #Log3 $name, 3, "$cmd $aName $aVal";
    if ( $cmd eq "set" ) {
        if ( $aName eq "hz_dayTimes" && $init_done ) {
            my $oVals = AttrVal( $name, "hz_dayTimes", $EMPTY );
            my @oldVals = map { ( split /\|/xsm, $_ )[1] } split( $SPACE, $oVals );
            my $bVal = $aVal;
            $bVal =~ s/\$SUNRISE/00:00/xsm;
            $bVal =~ s/\$SUNSET/00:00/xsm;
            return "$aName must be a space separated list of time|text pairs"
                if ( $bVal !~ /^([0-2]\d:[0-5]\d\|[\w\-äöüß\.]+)(\s[0-2]\d:[0-5]\d\|[\w\-äöüß\.]+){0,}$/i );

            my @newVals = map { ( split /\|/xsm, $_ )[1] } split( $SPACE, $aVal );
            my $userattr = AttrVal( $name, "userattr", $EMPTY );
            # create new userattributes if required
            foreach my $text (@newVals) {
                if ( grep ( /^$text$/xsm, @oldVals ) ) {
                    @oldVals = grep { $_ ne $text } @oldVals;
                }
                else {
                    my $ua = " hz_decay_" . $text;
                    $userattr .= $ua;
                }
            }

            # delete old Attributes
            foreach my $o (@oldVals) {
                my $r = "hz_decay_" . $o;
                $userattr =~ s/$r/ /xsm;
                CommandDeleteAttr( undef, "$name hz_decay_" . $o );
            }

            # update userattr
            CommandAttr( undef, "$name userattr $userattr" );
        }
        elsif ( $aName eq "hz_state" ) {
            foreach my $a ( split( $SPACE, $aVal ) ) {
                return "$aName must be a space separated list of probability:text pairs"
                    if ( !( $a =~ /(1\d\d|\d\d|\d):([\w\-äöüß\.]+)/xsm ) );
            }
            my $oVals = AttrVal( $name, "hz_state", $EMPTY );
            my @oldVals = map { ( split /:/, $_ )[1] } split( $SPACE, $oVals );
            Log3 $name, 5, "[homezone - $name]: Old States - " . join( $SPACE, @oldVals );

            my @newVals = map { ( split /:/, $_ )[1] } split( $SPACE, $aVal );
            Log3 $name, 5, "[homezone - $name]: New States - " . join( $SPACE, @newVals );

            my $userattr = AttrVal( $name, "userattr", $EMPTY );

            foreach my $text (@newVals) {
                if ( grep ( /^$text$/, @oldVals ) ) {
                    @oldVals = grep { $_ ne $text } @oldVals;
                    Log3 $name, 5, "[homezone - $name]: no update for $text ";
                }
                else {
                    my $ua = " hz_cmd_" . $text . ":textField-long";
                    $userattr .= $ua;
                    my $ua2 = " hz_lumiThreshold_" . $text;
                    $userattr .= $ua2;
                    Log3 $name, 5, "[homezone - $name]: new user attributes created for $text ";
                }
            }

            foreach my $o (@oldVals) {
                my $r = "hz_cmd_" . $o;
                $userattr =~ s/$r/ /;
                CommandDeleteAttr( undef, "$name $r" );
                $r = "hz_lumiThreshold_" . $o;
                $userattr =~ s/$r/ /;
                CommandDeleteAttr( undef, "$name $r" );
                Log3 $name, 5, "[homezone - $name]: user attributes deleted for $r";
            }

            # update userattr
            CommandAttr( undef, "$name userattr $userattr" );

        }
        elsif (
            (      $aName eq "hz_openEvent"
                or $aName eq "hz_closedEvent"
                or $aName eq "hz_occupancyEvent"
                or $aName eq "hz_absenceEvent"
            )
            && $init_done
            )
        {
            my @aw = split( $SPACE, ReadingsVal( $name, "associatedWith", $EMPTY ) );
            my @md = split( $SPACE, $aVal );
            foreach my $ma (@md) {
                Log3 $name, 1, $ma;
                foreach my $a ( split( $COMMA, $ma ) ) {
                    my ( $d, $e ) = split( ":", $a, 2 );
                    return "$d is not a valid device" if ( devspec2array($d) eq $d && !$defs{$d} );
                    return "Event not defined for $d" if ( !$e or $e eq $EMPTY );

                    foreach my $awd ( devspec2array($d) ) {
                        push( @aw, $awd ) unless grep ( /$d/, @aw );
                    }
                }
            }

            readingsSingleUpdate( $hash, "associatedWith", join( $SPACE, @aw ), 0 );
        }
        elsif ( $aName eq "hz_luminanceReading" && $init_done ) {
            my ( $d, $r ) = split( ":", $aVal );
            return "Couldn't get a luminance value for reading $r of device $d" if ReadingsVal( $d, $r, $EMPTY ) eq $EMPTY;

            my @aw = split( $SPACE, ReadingsVal( $name, "associatedWith", $EMPTY ) );
            push( @aw, $d ) unless grep ( /$d/, @aw );
            readingsSingleUpdate( $hash, "associatedWith", join( $SPACE, @aw ), 0 );
        }
        elsif ( $aName =~ /hz_lumiThreshold.*/ ) {
            return "$aName has to be in the form <low>:<high>" unless $aVal =~ /.*:.*/;
        }
        elsif ( $aName =~ /hz_decay.*/ ) {
            return "$aName should be a number (in seconds)" unless $aVal =~ /^\d+$/;
        }
        elsif ( ( $aName eq "hz_adjacent" or $aName eq "hz_children" ) && $init_done ) {
            foreach my $a ( split( $COMMA, $aVal ) ) {
                return "$a is not a homezone Device" if InternalVal( $a, "TYPE", $EMPTY ) eq $EMPTY;

                my @aw = split( $SPACE, ReadingsVal( $name, "associatedWith", $EMPTY ) );
                push( @aw, $a ) unless grep ( /$a/xsm, @aw );
                readingsSingleUpdate( $hash, "associatedWith", join( $SPACE, @aw ), 0 );

            }
        }
        elsif ( $aName =~ /hz_cmd_.*/ ) {
            if ( $aVal =~ m/^{.*}$/s ) {
                my %specials = ( "%name" => $name );

                #my $cmd = EvalSpecials($aVal, %specials);
                my $err = perlSyntaxCheck( $aVal, %specials );
                return $err if ($err);
            }
            my @aw = split( $SPACE, ReadingsVal( $name, "associatedWith", $EMPTY ) );
            my @cmds = split( $SPACE, $aVal );
            foreach my $cm (@cmds) {
                Log3( $name, 5, "[homezone - $name]: Checking if '$cm' is a device'" );
                if ( exists( $defs{$cm} ) ) {
                    Log3( $name, 5, "[homezone - $name]:Yes, '$cm' is a device'" );
                    push( @aw, $cm ) unless grep ( /$cm/xsm, @aw );;
                }
            }

            readingsSingleUpdate( $hash, "associatedWith", join( $SPACE, @aw ), 0 );

        }
        elsif ( $aName eq "disable" ) {
            if ( $aVal == 1 ) {
                RemoveInternalTimer($hash);
                readingsSingleUpdate( $hash, "state", "inactive", 1 );
            }
            elsif ( $aVal == 0 ) {
                readingsSingleUpdate( $hash, "state", "initialized", 1 );
            }

        }

    }
    elsif ( $cmd eq "del" ) {
        if ( $aName eq "disable" ) {
            readingsSingleUpdate( $hash, "state", "initialized", 1 );
            return;
        }
        if ( $aName eq "hz_dayTimes") {
            my $oVals = AttrVal( $name, "hz_dayTimes", $EMPTY );
            my @oldVals = map { ( split /\|/xsm, $_ )[1] } split( $SPACE, $oVals );
            my $userattr = AttrVal( $name, "userattr", $EMPTY );
            # delete old Attributes
            foreach my $o (@oldVals) {
                my $r = "hz_decay_" . $o;
                $userattr =~ s/$r/ /xsm;
                CommandDeleteAttr( undef, "$name hz_decay_" . $o );
            }

            # update userattr
            CommandAttr( undef, "$name userattr $userattr" );


        }

    }

    return;

}
###################################################################
# HELPER functions
###################################################################

sub homezone_dayTime($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my $daytimes = AttrVal( $name, "hz_dayTimes", "NA" );
    return $EMPTY if $daytimes eq "NA";

    my ( $sec, $min, $hour, $mday, $month, $year, $wday, $yday, $isdst ) = localtime;
    my $loctime = $hour * 60 + $min;
    my @texts;
    my @times;
    foreach ( split $SPACE, $daytimes ) {
        my ( $dt, $text ) = split /\|/;
        $dt = sunrise_abs() if $dt eq "\$SUNRISE";
        $dt = sunset_abs()  if $dt eq "\$SUNSET";
        my ( $h, $m, $s ) = split /:/, $dt;
        my $minutes = $h * 60 + $m;
        push @times, $minutes;
        push @texts, $text;
    }
    my $daytime = $texts[ scalar @texts - 1 ];
    for ( my $x = 0; $x < scalar @times; $x++ ) {
        my $y = $x + 1;
        $y = 0 if ( $x == scalar @times - 1 );
        $daytime = $texts[$x] if ( $y > $x && $loctime >= $times[$x] && $loctime < $times[$y] );
    }
    readingsSingleUpdate( $hash, "lastDayTime", $daytime, 0 );
    return $daytime;
}

###################################
sub homezone_decay($) {
    my ($hash) = @_;
    my $name   = $hash->{NAME};
    my $dt     = homezone_dayTime($hash);
    $dt = "_" . $dt if $dt ne $EMPTY;
    return AttrVal( $name, "hz_decay" . $dt, AttrVal( $name, "hz_decay", 0 ) );
}

###################################
sub homezone_getDoorState($) {
    my ($hash) = @_;
    my $name   = $hash->{NAME};
    my $open   = 0;
    my $i      = 1;
    while ( $i <= $hash->{HELPER}{doors} ) {
        if ( ReadingsVal( $name, "door" . $i, $EMPTY ) eq "open" ) {
            $open++;
        }
        $i++;
    }
    Log3 $name, 5, "[homezone - $name]: Found $open open doors out of $hash->{HELPER}{doors}";
    return "open"   if ( $open == $hash->{HELPER}{doors} );
    return "closed" if ( $open == 0 );
    return "partly closed";
}

1;

=pod
=item helper
=item summary Determine Presence in a "Zone" and act accordingly
=item summary_DE Anwesenheit in einer "Zone" erkennen und entsprechend reagieren
=begin html

<a name="homezone"></a>
<div>
<ul>
The idea of the module is to define "zones" in your house, determine if they are occupied and act depending on occupancy
<br><br><a name='homezoneDefine'></a>
        <b>Define</b>
        <ul>
define a zone with <code>define <name> homezone</code> without any additional parameters
</ul>
<a name='homezoneSet'></a>
        <b>Set</b>
        <ul>
<li><a name='active'>active</a>: enable the zone</li>
<li><a name='inactive'>inactive</a>: disable the zone</li>
<li><a name='closed'>closed</a>: Set a zone "closed"</li>
<li><a name='open'>open</a>: Set a zone "open"</li>
<li><a name='occupied'>occupied</a>: Set an "occupancy" value between 0 and 100</li>
 </ul>
<a name='homezoneAttr'></a>
        <b>Attributes</b>
        <ul>
<li><a name='hz_occupancyEvent'>hz_occupancyEvent</a>: Event that indicates presence (typically motion, but can also be "window open"). Format is <device regex>:<Event regex>, e.g. myMotionSensor:state:.motion. In all Event-Attributes it's possible to enter comma-separated lists of <device regex>:<Event regex> pairs.</li>
<li><a name='hz_absenceEvent'>hz_absenceEvent</a>: Event that definitely indicates absence, e.g. switching of the light or if a RESIDENTS device changes to absent</li>
<li><a name='hz_openEvent'>hz_openEvent</a>: Event (e.g. door contact) that indicates that a zone was opened. If a zone has multiple doors, Regexes might be separated by space.</li>
<li><a name='hz_closedEvent'>hz_closedEvent</a>: Event (e.g. door contact) that indicates that a room was closed</li>
<li><a name='hz_sleepRoommates'>hz_sleepRoommates</a>: comma-separated list of ROOMMATES that sleep in that room. If their status is "asleep" the zone will be set to "present"</li>
<li><a name='hz_boxMode'>hz_boxMode</a>: If boxMode is set to 1 occupancy in adjacent zones will lead to absence in current zone. </li>
<li><a name='hz_decay'>hz_decay</a>: "Decay" in seconds, i.e. the time that passes until occupancy goes to 0 after occupancy was detected. Value might be overridden by daytime speicifc attributes (see hz_dayTimes)</li>
<li><a name='hz_adjacent'>hz_adjacent</a>: comma separated list of adjacent zones (homezone devices). The occupancy value of the zone will be mirrored to adjacent zones (if it is higher the the adjacent zone value)</li>
<li><a name='hz_state'>hz_state</a>: list of space separated value:state pairs -> if occupancy >= Value, then state will be set. (Will be defaulted to 100:present 50:likely 1:unlikely 0:absent)</li>
<li><a name='hz_children'>hz_children</a>: comma separated list of "children", i.e. homezone devices. The highest occupancy value of the children will be passed to this device</li>
<li><a name='hz_dayTimes'>hz_dayTimes</a>: space separated list of time|text pairs (e.g.: 05:00|morning). Allows daytime-specific control of decay values. For each "text" a decay user attribute will be generated. The attribute will be automatically populated at "define". Values from HOMEMODE will be taken if available. $SUNRISE and $SUNSET might be used instead of times. To reload dayTimes from HOMEMODE, delete the attribute and restart FHEM or execute a "defmod" of your homezone.</li>
<li><a name='hz_cmd_<state>'>hz_cmd_<state></a>: User attributes will be created when setting hz_state. Each attribute can contain a command that will be triggered if the event occurs. Multiple commands are separated by ";". Instead of FHEM commands, Perl code is also possible (surrounded by {}) In perl code $name will be replaced by the device name. You can define daytime specific commands using newlines. Lines starting with "<daytime>:" will be executed during that daytime. You should also have a line with only the default command.. E.g. <br><code>attr hz_test hz_cmd_absent set hz_light off\<br>Morning:set hz_light 100</code></li>
<li><a name='hz_luminanceReading'>hz_luminanceReading</a>: Reading in <device>:<reading> notation that indicates a luminance value for the zone</li>
<li><a name='hz_lumiThreshold'>hz_lumiThreshold</a>: Two "." separated values that define lower and upper limits for brightness (from hz_luminance attribue) when commands will be executed (e.g. 0:40 - only if luminance is lower 40, the command will be executed). Lower or upper threshold may remain empty (e.g. "200:" command will only be triggered if luminance is > 200)</li>
<li><a name='hz_lumiThreshold_<state>'>hz_lumiThreshold_<state></a>: User attributes will be created when setting hz_state. Each attribute can have a threshold that will override the default threshold for this state</li>
<li><a name='hz_disableOnlyCmds'>hz_disableOnlyCmds</a>: if a device is disabled (regardless if permanently or "for interval" occupancy will still be detected and logged, however commands won't be executed.</li>
<li><a name='hz_doAlways'>hz_doAlways</a>: Usually "cmd_" commands are only executed on status change. If doAlways is set to 1, commands will also be executed if the (occupancy- or absence-)event is triggered without a status change</li>
            </ul>
   </ul>
</div>
=end html

=begin html_DE

<a name=></a>
<div>
<ul>
Die Idee des Moduls ist, "Zonen" im Haus zu definieren, Anwesenheiten zu bestimmen und darauf zu reagieren
<br><br><a name='Define'></a>
        <b>Define</b>
        <ul>
Definiere eine Zone mit <code>define <name> homezone</code> ohne weitere Parameter
</ul>
<a name='homezoneSet'></a>
        <b>Set</b>
        <ul>
<li><a name='active'>active</a>: aktiviere die Zone</li>
<li><a name='inactive'>inactive</a>: deaktiviere die Zone</li>
<li><a name='closed'>closed</a>: Setze eine Zone auf "geschlossen"</li>
<li><a name='open'>open</a>: Setze eine Zone auf "offen"</li>
<li><a name='occupied'>occupied</a>: Setze einen "Anwesenheitswert" zwischen 0 und 100</li>
 </ul>
<a name='homezoneAttr'></a>
        <b>Attributes</b>
        <ul>
<li><a name='hz_occupancyEvent'>hz_occupancyEvent</a>: Event das eine Anwesenheit signalisiert (also typischerweise Bewegung, kann aber auch z.B. "Fenster  auf" sein). Anzugeben in der Form <device regex>:<Event regex>, also z.B. myMotionSensor:state:.motion. Bei allen Event-Attributen können auch Komma-getrennte Listen von <device regex>:<Event regex> Paaren angegeben werden.</li>
<li><a name='hz_absenceEvent'>hz_absenceEvent</a>:  Event das eine sichere Abwesenheit signalisiert, z.B. wenn manuell das Licht ausgemacht wird, oder ein RESIDENTS device auf absent wechselt.</li>
<li><a name='hz_openEvent'>hz_openEvent</a>: Event (z.B. Türkontakt) das anzeigt, dass ein Raum geöffnet wurde. Wenn eine Zone mehrere Türen hat, werden die Regexe für jede Tür durch Leerzeichen getrennt angegeben </li>
<li><a name='hz_closedEvent'>hz_closedEvent</a>: Event (z.B. Türkontakt) das anzeigt, dass ein Raum geschlossen wurde</li>
<li><a name='hz_sleepRoommates'>hz_sleepRoommates</a>: Komma-getrennte Liste von ROOMMATES. Wenn ihr Status "asleep" ist, wird die Zone auf "anwesend" gesetzt</li>
<li><a name='hz_boxMode'>hz_boxMode</a>: Wenn der BoxMode auf 1 steht, wird Anwesenheit in angrenzenden Zonen als Abwesenheit in der aktuellen Zone interpretiert</li>
<li><a name='hz_decay'>hz_decay</a>: "Verfallszeit" in Sekunden, also die Zeit, die vergehen soll bis der Timer nach erkannter Bewegung auf 0 runter gezählt hat. Wird ggf. überteuert von tageszeitabhängiger Steuerung (siehe hz_dayTimes)</li>
<li><a name='hz_adjacent'>hz_adjacent</a>: Komma-getrennte Liste von angrenzenden Zonen (homezone Devices). Der Occupancy-Wert der Zone wird auf diese angrenzenden Zonen gespiegelt, sofern er höher ist als der der angrenzenden Zone)</li>
<li><a name='hz_state'>hz_state</a>: Leerzeichen getrennte Liste von Wert:State Paaren -> Wenn Anwesenheitswahrscheinlichkeit >= Wert, dann wird State als state gesetzt (wird beim define wie folgt gesetzt: 100:present 50:likely 1:unlikely 0:absent)</li>
<li><a name='hz_children'>hz_children</a>: Komma-getrennte Liste von "Kindern", d.h. homezone devices. Der höhste Anwesenheitswert der Kinder wird an die Zone "vererbt". </li>
<li><a name='hz_dayTimes'>hz_dayTimes</a>: Leerzeichen-getrennt Liste von Uhrzeit|Text Paaren (z.B.: 05:00|Morgen). Dient zur Steuerung tageszeitabhängiger decay-Werte. Für jeden "text" wird ein zugehöriges decay-Userattribut erzeugt, mit dem die korrespondierenden Decay-Werte gepflegt werden. Das Attribut wird beim Define automatisch gesetzt und - sofern vorhanden - mit dem Wert aus HOMEMODE gefüllt. Die variablen $SUNRISE und $SUNSET können anstatt Uhrzeit verwendet werden. Um die dayTimes aus HOMEMODE neu zu laden, lösche das Attribut und starte FHEM neu oder führe ein "defmod" der homerzone durch.</li>
<li><a name='hz_cmd_<state>'>hz_cmd_<state></a>: Userattribute werden beim setzen von hz_state erzeugt. Jedem der Attribute kann ein Kommando (z.B. set myLight on) mitgegeben werden, das beim Eintritt des states ausgeführt wird. Mehrere Kommandos werden durch ; getrennt. Statt FHEM Kommandos ist auch Perl Code (durch {} umschlossen) erlaubt. In Perlcode wird $name durch den Devicenamen ersetzt. Du kannst auch Tageszeit-abhängige Kommandos mit Hilfe von Zeilenumrüchen angeben. Jede Zeile, die mit <daytime>: beginnt wird während dieser Tageszeit ausgeführt.  Du solltest auch eine Zeile haben, die nur das Standard-Kommando enthält. Z.B.:  <br><code>attr hz_test hz_cmd_absent set hz_light off\<br>Morning:set hz_light 100</code></li>
<li><a name='hz_luminanceReading'>hz_luminanceReading</a>: Reading in der Form <device>:<reading> das den Helligkeitswert für die Zone angibt</li>
<li><a name='hz_lumiThreshold'>hz_lumiThreshold</a>: zwei durch ":" getrennte Werte für die untere und obere Schwelle der Helligkeit (aus hz_luminanceReading) bei der geschaltet werden soll (hz_cmd_<state). z.B. 0:40 (nur wenn Helligkeit < 40 ist wird Kommando ausgeführt), untere und obere Schwelle können auch leer bleiben (z.B. "200:" Es wird nur geschaltet, wenn die Helligkeit über 200 liegt) </li>
<li><a name='hz_lumiThreshold_<state>'>hz_lumiThreshold_<state></a>:  Userattribute werden beim setzen von hz_state erzeugt. Jedem der Attribute kann ein threshold übergeben werden, der den default threshold für diesen state übersteuert.</li>
<li><a name='hz_disableOnlyCmds'>hz_disableOnlyCmds</a>: Wenn ein device disabled ist (egal ob permanent oder "for Intervall) wird - sofern dieses Attribut auf "1" steht trotzdem noch Anwesenheit erkannt und geloggt wie üblich, es werden aber keine Cmds ausgeführt.</li>
<li><a name='hz_doAlways'>hz_doAlways</a>: Normalerweise werden die "cmd_" Befehle nur bei Statusänderung ausgeführt. Wenn doAlways auf 1 gesetzt ist, werden die Kommandos auch ausgeführt wenn das (occupancy- oder absence-) Event eintritt aber keine Statusänderung bewirkt.</li>
            </ul>
   </ul>
</div>
=end html_DE
=cut
