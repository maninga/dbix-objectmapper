package DBIx::ObjectMapper::Relation::BelongsTo;
use strict;
use warnings;
use base qw(DBIx::ObjectMapper::Relation);

sub initial_is_multi { 0 };

sub get {
    my $self = shift;
    $self->get_one(@_);
}

sub foreign_key {
    my ( $self, $class_table, $table ) = @_;
    return $class_table->get_foreign_key_by_table( $table );
}

sub identity_condition {
    my $self = shift;
    my $mapper = shift;
    my $class_mapper = $mapper->instance->__class_mapper__;
    my $rel_mapper = $self->mapper;

    my $fk = $self->foreign_key($class_mapper->table, $rel_mapper->table);

    my @cond;
    for my $i ( 0 .. $#{$fk->{keys}} ) {
        my $val = $mapper->get_val($fk->{keys}->[$i]);
        next unless defined $val;
        push @cond, $rel_mapper->table->c( $fk->{refs}->[$i] ) == $val;
    }

    return @cond;
}

sub relation_condition {
    my $self = shift;
    my $class_table = shift;
    my $table = shift;

    my $rel_table = $self->mapper->table;
    my $fk = $self->foreign_key( $class_table, $rel_table );

    my @cond;
    for my $i ( 0 .. $#{$fk->{keys}} ) {
        push @cond,
            $table->c( $fk->{refs}->[$i] )
                == $class_table->c($fk->{keys}->[$i]);
    }

    return @cond;
}

1;
