#
# Copyright (c) 2008 Rainer Clasen
# 
# This program is free software; you can redistribute it and/or modify
# it under the terms described in the file LICENSE included in this
# distribution.
#

=head1 NAME

Workout::Store::Tcx - read/write Garmin Training Center Database files

=head1 SYNOPSIS

  use Workout::Store::Tcx;

  $src = Workout::Store::Tcx->read( "foo.tcx" );

  $iter = $src->iterate;
  while( $chunk = $iter->next ){
  	...
  }

  $src->write( "out.tcx" );

=head1 DESCRIPTION

Interface to read/write Garmin Training Center Database files. Inherits
from Workout::Store and implements do_read/_write methods.

=cut

# http://developer.garmin.com/schemas/tcx/v2/

# verify with: 
# xmllint -noout --schema http://www.garmin.com/xmlschemas/TrainingCenterDatabasev2.xsd $fname

package Workout::Store::Tcx::Read;
1;
use base 'Workout::XmlDescent';
use strict;
use warnings;
use DateTime;
use Geo::Distance;
use Workout::Chunk;
use Carp;

# TODO: verify read values are numbers

our %nodes = (
	top	=> {
		trainingcenterdatabase	=> 'tcx'
	},

	tcx	=> {
		activities	=> 'activities',
		'*'		=> 'ignore',
	},

	activities	=> {
		activity	=> 'activity',
		#'*'		=> 'ignore',
	},

	activity	=> {
		'lap'	=> 'lap',
		'notes'	=> 'actnote',
		'*'	=> 'ignore',
	},
	actnote	=> undef,

	lap	=> {
		track	=> 'track',
		notes	=> 'lapnote',
		'*'	=> 'ignore',
	},
	lapnote	=> undef,

	track	=> {
		trackpoint	=> 'trackpoint'
		#'*'		=> 'ignore',
	},

	trackpoint	=> {
		time		=> 'trktime',
		position	=> 'trkpos',
		altitudemeters	=> 'trkele',
		distancemeters	=> 'trkodo',
		heartratebpm	=> 'trkhrbpm',
		cadence		=> 'trkcad',
		extensions	=> 'trkextensions',
		'*'		=> 'ignore',
	},
	trkpos	=> {
		latitudedegrees		=> 'trklat',
		longitudedegrees	=> 'trklon',
	},
	trkhrbpm	=> {
		value	=> 'trkhr',
	},
	trkextensions	=> {
		tpx	=> 'trktpx',
		'*'	=> 'ignore',
	},
	trktpx => {
		watts	=> 'trkpwr',
		'*'	=> 'ignore',
	},
	trktime	=> undef,
	trklat	=> undef,
	trklon	=> undef,
	trkodo	=> undef,
	trkele	=> undef,
	trkcad	=> undef,
	trkhr	=> undef,
	trkpwr	=> undef,

	ignore	=> {
		'*'	=> 'ignore',
	},
);

our $re_time = qr/^\s*(-?\d\d\d\d+)-(\d\d)-(\d\d)	# date
	T(\d\d):(\d\d):(\d\d(.\d+)?)			# time
	(?:(Z)|(([+-]\d\d):(\d\d)))?\s*$/x;		# zone

sub _str2time {
	my( $time ) = @_;

	my( $year, $mon, $day, $hour, $min, $sec, $nsec, $z, $zhour, $zmin ) 
		= ( $time =~ /$re_time/ )
		or croak "invalid time format: $time";

	if( $z || !defined $zhour || ! defined $zmin ){
		$zhour = '+00';
		$zmin = '00';
	}
	$nsec ||= 0;

	DateTime->new(
		year	=> $year,
		month	=> $mon,
		day	=> $day,
		hour	=> $hour,
		minute	=> $min,
		second	=> $sec,
		nanosecond	=> $nsec * 1000000000,
		time_zone	=> $zhour.$zmin,
	)->hires_epoch;
}

sub new {
	my $proto = shift;
	my $a = shift || {};

	$proto->SUPER::new({
		Store	=> undef,
		%$a,
		nodes	=> \%nodes,
		gcalc	=> Geo::Distance->new,
		actnote	=> undef,
		lapnote	=> undef,
		laps	=> [],
		pt	=> {}, # current point
		lpt	=> undef, # last point
		field_use	=> {},
	});
}

sub end_leaf {
	my( $self, $el, $node ) = @_;

	my $name = $node->{node};
	#print STDERR "end_leaf $name\n";
	if( $name eq 'trktime' ){
		$self->{pt}{time} = _str2time( $node->{cdata} );

	} elsif( $name eq 'trklon' ){
		$self->{pt}{lon} = $node->{cdata};
		++$self->{field_use}{lon};

	} elsif( $name eq 'trklat' ){
		$self->{pt}{lat} = $node->{cdata};
		++$self->{field_use}{lat};

	} elsif( $name eq 'trkodo' ){
		$self->{pt}{odo} = $node->{cdata};

	} elsif( $name eq 'trkele' ){
		$self->{pt}{ele} = $node->{cdata};
		++$self->{field_use}{ele};

	} elsif( $name eq 'trkcad' ){
		$self->{pt}{cad} = $node->{cdata};
		++$self->{field_use}{cad};

	} elsif( $name eq 'trkpwr' ){
		$self->{pt}{pwr} = $node->{cdata};
		++$self->{field_use}{work};

	} elsif( $name eq 'trkhr' ){
		$self->{pt}{hr} = $node->{cdata};
		++$self->{field_use}{hr};

	} elsif( $name eq 'lapnote' ){
		$self->{lapnote} = $node->{cdata};

	} elsif( $name eq 'actnote' ){
		# TODO: silently merges multiple activities
		$self->{actnote} ||= $node->{cdata};
	}
}

sub end_node {
	my( $self, $el, $node ) = @_;

	my $name = $node->{node};
	#print STDERR "end_node $name\n";
	if( $name eq 'trackpoint' ){
		$self->end_trackpoint( $node->{attr} );

	} elsif( $name eq 'track' ){
		$self->{lpt} = undef;

	} elsif( $name eq 'lap' ){
		if( my $endtime = $self->{Store}->time_end ){
			push @{ $self->{laps} }, {
				note	=> $self->{lapnote},
				end	=> $endtime,
			};
		}
		$self->{lapnote} = undef;

	} elsif( $name eq 'activity' ){
		$self->{Store}->note( $self->{actnote} );
		$self->{Store}->mark_new_laps( $self->{laps} );
		$self->{laps} = [];

	}
}

sub end_trackpoint {
	my( $self, $attr ) = @_;

	my $pt = $self->{pt};
	$self->{pt} = {};

	return unless $pt->{time};
	#print STDERR "end_trackpoint $pt->{time}\n";

	# TODO: calc dur from <Lap StartTime="...">
	my $dur = 0.015;
	my $dist = $pt->{odo} || 0;

	if( defined( my $lpt = $self->{lpt} ) ){
		$dur = $pt->{time} - $lpt->{time};

		if( defined $pt->{odo} && defined $lpt->{odo} ){
			$dist = $pt->{odo} - $lpt->{odo};
			++$self->{field_use}{dist};

		} elsif( defined $pt->{lon} && defined $pt->{lat}
			&& defined $lpt->{lon} && defined $lpt->{lat} ){

			$dist = $self->{gcalc}->distance( 'meter',
				$lpt->{lon}, $lpt->{lat},
				$pt->{lon}, $pt->{lat},
			);
			++$self->{field_use}{dist};
		}

		$pt->{work} = $pt->{pwr} * $dur
			if $lpt && defined $pt->{pwr};
	}

	return if $dur < 0.01;

	delete $pt->{pwr};
	# delete $pt->{odo}; # needed for next pt to calc dist

	$self->{Store}->chunk_add( Workout::Chunk->new({
		%$pt,
		dur     => $dur,
		dist    => $dist,
	}) );

	$self->{lpt} = $pt;
}

sub end_document {
	my( $self ) = @_;

	my @fields;

	foreach my $f ( keys %{ $self->{field_use} } ){
		push @fields, $f if $self->{field_use}{$f};
	};

	$self->{Store}->fields_io( @fields );

	$self->{field_use} = {};
	$self->{actnote} = undef;

	1;
}


package Workout::Store::Tcx;
use 5.008008;
use strict;
use warnings;
use base 'Workout::Store';
use XML::SAX;
use Carp;

our $VERSION = '0.01';

sub filetypes {
	return "tcx";
}

our %fields_supported = map { $_ => 1; } qw{
	lon
	lat
	dist
	ele
	cad
	hr
	work
};


=head1 CONSTRUCTOR

=head2 new( [ \%arg ] )

creates an empty Store.

=cut

sub new {
	my( $class, $a ) = @_;

	$a ||= {};
	my $self = $class->SUPER::new( {
		%$a,
		fields_supported	=> {
			%fields_supported,
		},
		cap_block	=> 1,
		cap_note	=> 1,
	});
	$self;
}

sub do_read {
	my( $self, $fh, $fname ) = @_;

	my $parser = XML::SAX::ParserFactory->parser(
		Handler	=> Workout::Store::Tcx::Read->new({
			Store	=> $self,
		}),
	) or croak 'cannot start parser';

	$parser->parse_file( $fh )
		or croak "parse failed: $!";

}


sub _time2str {
	my( $time ) = @_;

	my $d = DateTime->from_epoch(
		epoch	=> $time,
		time_zone	=> 'UTC',
	);
	return $d->nanosecond
		? $d->strftime( '%Y-%m-%dT%H:%M:%S.%6NZ' )
		: $d->strftime( '%Y-%m-%dT%H:%M:%SZ' );
}

sub do_write {
	my( $self, $fh, $fname ) = @_;

	$self->chunk_count
		or croak "no data";

	binmode( $fh, ':encoding(utf8)' );

	my %write = map {
		$_ => 1;
	} $self->fields_io;
	$self->debug( "writing fields: ", join(",", keys %write ) );

	my $stime = _time2str($self->time_start);
	my $laps = $self->laps;

	# TODO: Sport = Biking|Running|Other

	print $fh <<EOHEAD;
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2 http://www.garmin.com/xmlschemas/TrainingCenterDatabasev2.xsd">
<Activities>
<Activity Sport="Biking">
<Id>$stime</Id>
EOHEAD

	foreach my $lap (@$laps){

		my $info = $lap->info;
		my $ltime = _time2str($info->time_start);

		print $fh "<Lap StartTime=\"", $ltime, "\">\n",
			"<TotalTimeSeconds>", $info->dur, "</TotalTimeSeconds>\n",
			"<DistanceMeters>", ($info->dist || 0), "</DistanceMeters>\n",
			"<MaximumSpeed>", ($info->spd_max || 0), "</MaximumSpeed>\n",
			"<Calories>", int( ($info->work || 0) / 1000 ), "</Calories>\n";

		print $fh "<AverageHeartRateBpm>\n",
			"<Value>", int($info->hr_avg || 0), "</Value>\n",
			"</AverageHeartRateBpm>\n",
			"<MaximumHeartRateBpm>\n",
			"<Value>", int($info->hr_max || 0), "</Value>\n",
			"</MaximumHeartRateBpm>\n"
			if $write{hr};

		# TODO: Intensity = Active|Resting
		print $fh "<Intensity>Active</Intensity>\n";

		print $fh "<Cadence>", int($info->cad_avg || 0), "</Cadence>\n"
			if $write{cad};

		print $fh "<TriggerMethod>Manual</TriggerMethod>\n",
			"<Track>\n";

		my $it = $lap->iterate;
		my $odo = 0;

		while( my $c = $it->next ){
			$odo += $c->dist || 0;

			print $fh "<Trackpoint>\n",
				"<Time>", _time2str($c->time),"</Time>\n";

			print $fh "<Position>\n",
				"<LatitudeDegrees>", $c->lat,"</LatitudeDegrees>\n",
				"<LongitudeDegrees>", $c->lon,"</LongitudeDegrees>\n",
				"</Position>\n" if ( $write{lon} || $write{lat} )
				&& defined $c->lon && defined $c->lat;

			print $fh "<AltitudeMeters>", $c->ele,"</AltitudeMeters>\n"
				if $write{ele} && defined $c->ele;

			print $fh "<DistanceMeters>", $odo,"</DistanceMeters>\n"
				if $write{dist};

			if( $write{hr} && 0 < (my $hr = int($c->hr || 0)) ){
				print $fh "<HeartRateBpm>\n",
					"<Value>", $hr,"</Value>\n",
					"</HeartRateBpm>\n";
			}

			print $fh "<Cadence>", $c->cad,"</Cadence>\n"
				if $write{cad} && defined $c->cad;

			# TODO: SensorState = Absent|Present
			print $fh "<SensorState>Present</SensorState>\n";

			print $fh "<Extensions>\n",
				"<TPX xmlns=\"http://www.garmin.com/xmlschemas/ActivityExtension/v2\">\n",
				"<Watts>", $c->pwr, "</Watts>\n",
				"</TPX>\n",
				"</Extensions>\n"
				if $write{work} && defined $c->pwr;

			print $fh "</Trackpoint>\n";
		}

		print $fh "</Track>\n",
			"<Notes>", ($lap->note || ''), "</Notes>\n";

		print $fh "<Extensions>\n",
			"<LX xmlns=\"http://www.garmin.com/xmlschemas/ActivityExtension/v2\">\n",
			"<AvgWatts>", $info->pwr_avg, "</AvgWatts>\n",
			"</LX>\n",
			"</Extensions>\n"
			if $write{work} && defined $info->pwr_avg;

		print $fh "</Lap>\n";
	}

	print $fh "<Notes>", ($self->note || ''), "</Notes>\n";

	# TODO: write marker as extension?

	print $fh "</Activity>\n",
		"</Activities>\n",
		"</TrainingCenterDatabase>\n";
}

1;
__END__

=head1 SEE ALSO

Workout::Store, Workout::XmlDescent, XML::SAX

=head1 AUTHOR

Rainer Clasen

=cut
