#!/usr/bin/perl -w

use strict;
use warnings;
use DBI;
use Time::Local qw(timelocal);
use Astro::MoonPhase qw(phase phasehunt);

my $now = time();

my $phase_payload = build_phase_payload($now);
my $sign_payload  = build_sign_payload($now);

my $dsn = "DBI:mysql:host=localhost;database=__DATABASE__";
my $dbh = DBI->connect(
    $dsn,
    "__USERNAME__",
    "__PASSWORD__",
    {
        RaiseError => 1,
        PrintError => 0,
        AutoCommit => 1,
    }
) or die "can not connect to server.\n";

eval {
    $dbh->begin_work;
    insert_moon_phase($dbh, $phase_payload);
    insert_moon_sign($dbh, $sign_payload);
    $dbh->commit;
    1;
} or do {
    my $error = $@ || "unknown database error";
    eval { $dbh->rollback };
    die $error;
};

$dbh->disconnect;

exit(0);

sub build_phase_payload {
    my ($epoch) = @_;

    my ($moonphase, $moonillum, $moonage, $moondist, $moonang, $sundist, $sunang) = phase($epoch);
    my $phase_name = moon_phase_name($moonphase);
    my $moon_age   = sprintf("%.2f", $moonage);

    my ($sec, $min, $hour, $dom, $month, $year, $wday, $yday, $idst) = gmtime($epoch);
    my $phasehunt_epoch = timelocal(0, 0, 0, 15, $month, $year + 1900);
    my @phases = phasehunt($phasehunt_epoch);

    return {
        date   => $epoch,
        phase2 => $phase_name,
        phase  => $moon_age,
        nmoon  => int($phases[0]),
        fq     => int($phases[1]),
        fmoon  => int($phases[2]),
        lq     => int($phases[3]),
        xnmoon => int($phases[4]),
    };
}

sub build_sign_payload {
    my ($epoch) = @_;

    my ($sign, $deg, $lon) = moon_sign($epoch);
    my $degree_symbol = chr(176);

    return {
        sign => sprintf("%s", $sign),
        deg  => sprintf("%0.2f%s", $deg, $degree_symbol),
        lon  => sprintf("%0.4f%s", $lon, $degree_symbol),
    };
}

sub insert_moon_phase {
    my ($dbh, $payload) = @_;

    my $sth = $dbh->prepare(
        "INSERT INTO moonphase ( `date`, `phase2`, `phase`, `nmoon`, `fq`, `fmoon`, `lq`, `xnmoon` ) VALUES (?,?,?,?,?,?,?,?)"
    );

    $sth->execute(
        $payload->{date},
        $payload->{phase2},
        $payload->{phase},
        $payload->{nmoon},
        $payload->{fq},
        $payload->{fmoon},
        $payload->{lq},
        $payload->{xnmoon},
    );
}

sub insert_moon_sign {
    my ($dbh, $payload) = @_;

    my $sth = $dbh->prepare(
        "INSERT INTO moonsign ( `sign`, `deg`, `lon` ) VALUES (?,?,?)"
    );

    $sth->execute(
        $payload->{sign},
        $payload->{deg},
        $payload->{lon},
    );
}

sub moon_ecliptic_longitude_deg {
    my ($epoch) = @_;
    $epoch = time() unless defined $epoch;

    no strict 'refs';

    my $Epoch    = $Astro::MoonPhase::Epoch;
    my $Elonge   = $Astro::MoonPhase::Elonge;
    my $Elongp   = $Astro::MoonPhase::Elongp;
    my $Eccent   = $Astro::MoonPhase::Eccent;
    my $Mmlong   = $Astro::MoonPhase::Mmlong;
    my $Mmlongp  = $Astro::MoonPhase::Mmlongp;
    my $Mlnode   = $Astro::MoonPhase::Mlnode;
    my $Minc     = $Astro::MoonPhase::Minc;

    my $jtime    = \&Astro::MoonPhase::jtime;
    my $fixangle = \&Astro::MoonPhase::fixangle;
    my $kepler   = \&Astro::MoonPhase::kepler;
    my $todeg    = \&Astro::MoonPhase::todeg;
    my $dsin     = \&Astro::MoonPhase::dsin;
    my $dcos     = \&Astro::MoonPhase::dcos;

    my $pdate = $jtime->($epoch);
    my $Day   = $pdate - $Epoch;

    my $N         = $fixangle->((360 / 365.2422) * $Day);
    my $M         = $fixangle->($N + $Elonge - $Elongp);
    my $Ec        = $kepler->($M, $Eccent);
    $Ec           = sqrt((1 + $Eccent) / (1 - $Eccent)) * tan($Ec / 2);
    $Ec           = 2 * $todeg->(Astro::MoonPhase::atan($Ec));
    my $Lambdasun = $fixangle->($Ec + $Elongp);

    my $ml  = $fixangle->(13.1763966 * $Day + $Mmlong);
    my $MM  = $fixangle->($ml - 0.1114041 * $Day - $Mmlongp);
    my $MN  = $fixangle->($Mlnode - 0.0529539 * $Day);

    my $Ev  = 1.2739 * $dsin->(2 * ($ml - $Lambdasun) - $MM);
    my $Ae  = 0.1858 * $dsin->($M);
    my $A3  = 0.37   * $dsin->($M);
    my $MmP = $MM + $Ev - $Ae - $A3;
    my $mEc = 6.2886 * $dsin->($MmP);
    my $A4  = 0.214  * $dsin->(2 * $MmP);
    my $lP  = $ml + $Ev + $mEc - $Ae + $A4;
    my $V   = 0.6583 * $dsin->(2 * ($lP - $Lambdasun));
    my $lPP = $lP + $V;
    my $NP  = $MN - 0.16 * $dsin->($M);

    my $y = $dsin->($lPP - $NP) * $dcos->($Minc);
    my $x = $dcos->($lPP - $NP);

    my $Lambdamoon = $todeg->(atan2($y, $x)) + $NP;
    return $fixangle->($Lambdamoon);
}

sub moon_sign {
    my ($epoch) = @_;

    my $lon = moon_ecliptic_longitude_deg($epoch);
    my @signs = qw(
        Aries Taurus Gemini Cancer Leo Virgo
        Libra Scorpio Sagittarius Capricorn Aquarius Pisces
    );

    my $idx = int($lon / 30) % 12;
    my $deg_in_sign = $lon - 30 * $idx;

    return ($signs[$idx], $deg_in_sign, $lon);
}

sub moon_phase_name {
    my ($phase) = @_;

    return "New Moon"        if $phase < 0.0625;
    return "Waxing Crescent" if $phase < 0.2475;
    return "First Quarter"   if $phase < 0.2725;
    return "Waxing Gibbous"  if $phase < 0.4875;
    return "Full Moon"       if $phase < 0.5428;
    return "Waning Gibbous"  if $phase < 0.7375;
    return "Last Quarter"    if $phase < 0.7805;
    return "Waning Crescent" if $phase < 0.9142;
    return "Dark Moon";
}
