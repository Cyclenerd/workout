package Workout::Filter::Timeshift;

=head1 NAME

Workout::Filter::Timeshift - Timeshift Workout data

=head1 SYNOPSIS

  $src = Workout::Store::SRM->read( "foo.srm" );
  $join = Workout::Filter::Timeshift->new( $src );
  while( my $chunk = $join->next ){
  	# do something
  }

=head1 DESCRIPTION

Iterator that automagically fills the gaps between individual data blocks
with fake chunks.

=cut

use 5.008008;
use strict;
use warnings;
use base 'Workout::Filter::Base';
use Carp;

our $VERSION = '0.01';

our %default = (
	delta	=> 0,
);

__PACKAGE__->mk_accessors(keys %default );

=head2 new( $src, $arg )

new iterator

=cut

sub new {
	my( $class, $src, $a ) = @_;

	$a ||= {};
	my $self = $class->SUPER::new( $src, {
		%default,
		%$a,
	});
	$self->{prev} = undef;
	$self;
}

=head2 next

get next data chunk

=cut

sub next {
	my( $self ) = @_;

	my $i = $self->src->next
		or return;
	$self->{cntin}++;
	$self->{cntout}++;

	my $o = $i->clone;
	$o->{time} += $self->delta;

	if( $i->{prev} ){
		$o->{prev} = $self->{prev};
	}
	$self->{prev} = $o;
	$o;
}


1;
__END__

=head1 SEE ALSO

Workout::Filter::Base

=head1 AUTHOR

Rainer Clasen

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2008 by Rainer Clasen

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.8 or,
at your option, any later version of Perl 5 you may have available.


=cut