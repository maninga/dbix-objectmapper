package DBIx::ObjectMapper::Mapper;
use strict;
use warnings;
use Carp::Clan qw/^DBIx::ObjectMapper/;
use List::MoreUtils;
use Scalar::Util qw(blessed weaken);
use Digest::MD5 qw(md5_hex);
use Params::Validate qw(:all);
use Class::MOP;
use Class::MOP::Class;
use Log::Any qw($log);

use DBIx::ObjectMapper::Utils;
use DBIx::ObjectMapper::Mapper::Instance;
use DBIx::ObjectMapper::Mapper::Constructor;
use DBIx::ObjectMapper::Mapper::Accessor;
use DBIx::ObjectMapper::Mapper::Attribute;
use DBIx::ObjectMapper::Metadata::Query;
use DBIx::ObjectMapper::Session::Array;

{
    my %INITIALIZED_CLASSES;

    sub _set_initialized_class {
        my $self = shift;
        $INITIALIZED_CLASSES{$self->mapped_class} = 1;
    }

    sub is_initialized {
        my $self = shift;
        my $class = shift;
        return $INITIALIZED_CLASSES{$class};
    }

    sub DESTROY {
        my $self = shift;
        warn "DESTROY $self" if $ENV{MAPPER_DEBUG};
        delete $INITIALIZED_CLASSES{ $self->mapped_class }
            if $self->mapped_class;
    }

    my %POLYMORPHIC_TREE;

    sub get_polymorphic_tree {
        my $self = shift;
        my $tree = $POLYMORPHIC_TREE{$self->mapped_class} || +{};
        my @tree = map{ [ $_ => $tree->{$_} ] } keys %$tree;
        for my $child_class ( keys %$tree ) {
            my @child_tree
                = $child_class->__class_mapper__->get_polymorphic_tree;
            unshift @tree, @child_tree;
        }
        return @tree;
    }

    sub set_polymorphic_tree {
        my $self = shift;
        my $tree = $POLYMORPHIC_TREE{$self->inherits} ||= +{};
        return $tree->{$self->mapped_class} = [
            $self->table->c($self->polymorphic_on),
            $self->polymorphic_identity,
        ];
    }
};

sub new {
    my $class = shift;

    if( $class->is_initialized($_[1]) ) {
        cluck "$_[1] is already initialized.";
        return $_[1]->__class_mapper__;
    }

    if( ref $_[0] eq 'ARRAY' ) {
        my ( $query, $alias_name, $param ) = @{$_[0]};
        $_[0] = DBIx::ObjectMapper::Metadata::Query->new(
            $alias_name => $query, $param || +{}
        );
    }

    unshift @_, 'table';
    splice @_, 2, 0, 'mapped_class';
    my %input_option = @_;
    my @input = @_;
    my $is_class_table_inheritance = 0;

    if( my $inh = $input_option{inherits} ) {
        my $orig_mapper;
        if( $class->is_initialized($inh) ) {
            $orig_mapper = $inh->__class_mapper__;
        }
        else {
            confess "$inh is not intialized.";
        }
        my $mapped_class = $input_option{mapped_class};
        my $orig_option = DBIx::ObjectMapper::Utils::clone(
            $orig_mapper->{input_option}
        );

        my $orig_table = $orig_option->{table};
        if( ref $orig_table eq 'DBIx::ObjectMapper::Metadata::Polymorphic' ) {
            $orig_table = $orig_table->child_table;
        }
        my $input_table = $input_option{table};

        if ( $orig_table->table_name ne $input_table->table_name ) {
            $is_class_table_inheritance = 1;
            require DBIx::ObjectMapper::Metadata::Polymorphic;
            $input_option{table}
                = DBIx::ObjectMapper::Metadata::Polymorphic->new(
                    $orig_option->{table}, $input_option{table}
                );
        }
        else {
            $input_option{table} = $orig_option->{table};
        }

        my $option = DBIx::ObjectMapper::Utils::merge_hashref(
            $orig_option,
            \%input_option,
        );
        @input = %$option;
    }

    my %option = validate(
        @input,
        {   table => {
                type => OBJECT,
                isa  => 'DBIx::ObjectMapper::Metadata::Table'
            },
            mapped_class         => { type => SCALAR, },
            attributes           => { type => HASHREF, default => +{} },
            accessors            => { type => HASHREF, default => +{} },
            constructor          => { type => HASHREF, default => +{} },
            default_condition    => { type => ARRAYREF, default => +[] },
            default_value        => { type => HASHREF, default => +{} },
            inherits             => { type => SCALAR, optional => 1 },
            polymorphic_on       => { type => SCALAR, optional => 1 },
            polymorphic_identity => { type => SCALAR, optional => 1 },
        }
    );

    my $self = bless {
        table                => $option{table},
        mapped_class         => $option{mapped_class},
        default_condition    => $option{default_condition},
        default_value        => $option{default_value},
        input_option         => \%option,
        inherits             => $option{inherits},
        polymorphic_on       => $option{polymorphic_on} || undef,
        polymorphic_identity => $option{polymorphic_identity} || undef,
        attributes           => +{},
        accessors            => +{},
        constructor          => +{},
        mapped               => 0,
    }, $class;

    $self->_init_constructor_config( %{ $option{constructor} } );
    $self->_init_attributes_config( %{ $option{attributes} } );
    $self->_init_acceesors_config( %{ $option{accessors} } );

    if( $self->polymorphic_on and $self->polymorphic_identity ) {
        # XXXXX 多段継承している場合は、親にさらに条件を追加する
        # if (    $is_class_table_inheritance
        #     and $dc->[0]->name eq $self->polymorphic_on )
        # {

        # for my $i ( 0 .. $#default_condition ) {
        #     my $dc = $default_condition[$i];
        #         my $parent_val = $self->default_condition->[$i]->[1][2];
        #         if ( $parent_val ne $self->polymorphic_identity ) {
        #             $self->default_condition->[$i]->[1]
        #                 = [ $self->table->c( $self->polymorphic_on )
        #                     == [ $parent_val, $self->polymorphic_identity, ]
        #                 ];
        #             splice( @default_condition, $i, 1 );
        #         }
        #     }
        # }

        my @default_condition;
        push @default_condition,
            $self->table->c($self->polymorphic_on)
                == $self->polymorphic_identity;
        $self->{default_condition} = \@default_condition;
        $self->default_value->{$self->polymorphic_on}
            = $self->polymorphic_identity;
    }

    if (    $self->inherits
        and $self->polymorphic_on
        and $self->polymorphic_identity )
    {
        $self->set_polymorphic_tree();
    }

    $self->_initialize;
    return $self;
}

sub _init_constructor_config {
    $_[0]->{constructor} = DBIx::ObjectMapper::Mapper::Constructor->new(@_);
}

sub _init_acceesors_config {
    $_[0]->{accessors} = DBIx::ObjectMapper::Mapper::Accessor->new(@_);
}

sub _init_attributes_config {
    $_[0]->{attributes} = DBIx::ObjectMapper::Mapper::Attribute->new(@_);
}

{
    no strict 'refs';
    my $package = __PACKAGE__;
    for my $meth (qw(table mapped_class attributes accessors
                     constructor default_condition default_value
                     inherits polymorphic_on polymorphic_identity)) {
        *{"$package\::$meth"} = sub { $_[0]->{$meth} };
    }
};

sub _initialize {
    my $self = shift;

    my $mapped_class = $self->mapped_class;
    unless( DBIx::ObjectMapper::Utils::loaded($mapped_class) ) {
        if( DBIx::ObjectMapper::Utils::installed($mapped_class) ) {
            DBIx::ObjectMapper::Utils::load_class($mapped_class);
        }
        elsif( $self->accessors->auto and $self->constructor->auto ) {
            # nothing
        }
        else {
            # die
            confess "\n====================================================\n$mapped_class is not installed.\nIf you want auto generate this class, Please set true the constructor->{auto} options and the accessors->{auto} options.\nIf this message is adverse, the $mapped_class has errors or you get typos.\n====================================================\n";
        }
    }

    my $meta;
    my %immutable_options = (
        inline_constructor => 0,
        inline_accessors   => 0,
        inline_destructor  => 0,
    );

    ## Mo[ou]se Class
    if( my $exmeta = Class::MOP::get_metaclass_by_name($self->mapped_class) ) {
        $meta = $exmeta;
        if( my %ex_immutable_options = $meta->immutable_options ) {
            %immutable_options = %ex_immutable_options;
        }
        $meta->make_mutable if $meta->is_immutable;
    }
    ## Plain Perl Class
    else {
        $meta = Class::MOP::Class->create($self->mapped_class);
    };

    $meta->add_method( '__class_mapper__' => sub { $self } );

    $meta->add_method(
        '__mapper__' => sub {
            my $instance = shift;
            if( blessed($instance) ){
                DBIx::ObjectMapper::Mapper::Instance->new( $instance );
            }
        }
    );

    my $generic_getter = $self->accessors->generic_getter;
    my $generic_setter = $self->accessors->generic_setter;
    if ( $generic_getter and $generic_setter ) {
        if( $generic_getter eq $generic_setter ) {
            $meta->add_before_method_modifier(
                $generic_getter => sub {
                    my $instance = shift;
                    my $mapper = $instance->__mapper__;
                    return unless $mapper;
                    if ( !$DBIx::ObjectMapper::Mapper::Instance::call ) {
                        if( @_ == 1 ) {
                            $mapper->get_val_trigger(@_);
                        }
                        elsif( @_ == 2 ) {
                            $mapper->set_val_trigger(@_);
                        }
                    }
                }
            );
        }
        else {
            $meta->add_before_method_modifier(
                $generic_getter => sub {
                    my $instance = shift;
                    my $mapper = $instance->__mapper__;
                    return unless $mapper;
                    if ( !$DBIx::ObjectMapper::Mapper::Instance::call ) {
                        $mapper->get_val_trigger(@_);
                    }
                }
            );

            $meta->add_before_method_modifier(
                $generic_setter => sub {
                    my $instance = shift;
                    my $mapper = $instance->__mapper__;
                    return unless $mapper;
                    if ( !$DBIx::ObjectMapper::Mapper::Instance::call ) {
                        $mapper->set_val_trigger(@_);
                    }
                }
            );
        }
    }

    for my $prop_name ( $self->attributes->property_names ) {
        next if $self->accessors->exclude->{$prop_name};
        my $property = $self->attributes->property_info($prop_name);
        if( $self->accessors->auto ) {
            if ( $meta->find_all_methods_by_name($prop_name)
                and !$self->accessors->do_replace )
            {
                confess "the method '$prop_name' is already exists.\nPlease use the accessors->{do_replace} option, or accessors->{exclude} option.";
            }
            else {
                $meta->add_method (
                    $prop_name => sub {
                        my $obj = shift;
                        if ( @_ ) {
                            my $val = shift;
                            $obj->{$prop_name} = $val;
                        }
                        return $obj->{$prop_name};
                    }
                );
            }
        }

        my $getter = $property->getter || $prop_name;
        my $setter = $property->setter || $prop_name;
        if( $getter eq $setter ) {
            next if $generic_getter and $generic_setter
                and !$mapped_class->can($getter);

            $meta->add_before_method_modifier(
                $getter => sub {
                    my $instance = shift;
                    my $mapper = $instance->__mapper__;
                    return unless $mapper;
                    if ( !$DBIx::ObjectMapper::Mapper::Instance::call ) {
                        if( @_ ) {
                            $mapper->set_val_trigger( $prop_name, @_ );
                        }
                        else {
                            $mapper->get_val_trigger( $prop_name );
                        }
                    }
                }
            );
        }
        else {
            $meta->add_before_method_modifier(
                $getter => sub {
                    my $instance = shift;
                    my $mapper = $instance->__mapper__;
                    return unless $mapper;
                    if ( !$DBIx::ObjectMapper::Mapper::Instance::call ) {
                        $mapper->get_val_trigger( $prop_name );
                    }
                }
            );

            $meta->add_before_method_modifier(
                $setter => sub {
                    my $instance = shift;
                    my $mapper = $instance->__mapper__;
                    return unless $mapper;
                    if ( !$DBIx::ObjectMapper::Mapper::Instance::call ) {
                        $mapper->set_val_trigger( $prop_name, @_ );
                    }
                }
            );
        }
    }

    if( $self->constructor->auto ) {
        confess "constructor method 'new' already exists."
            if $meta->find_all_methods_by_name('new');
        $self->constructor->set_arg_type('HASHREF');
        $self->constructor->set_name('new');
        $meta->add_method(
            new => sub {
                my $class = shift;
                my %param = @_ % 2 == 0 ? @_ : %{$_[0]};
                return bless \%param, $class;
            }
        );
    }

    my $destroy = sub {
        my $instance = shift;
        warn "DESTROY $instance" if $ENV{MAPPER_DEBUG};
        if ( blessed($instance)
            and my $mapper = DBIx::ObjectMapper::Mapper::Instance->get(
                $instance
            )
        ) {
            $mapper->demolish;
        }
    };

    if ( $meta->find_all_methods_by_name('DESTROY') ) {
        $meta->add_after_method_modifier('DESTROY' => $destroy );
    }
    else {
        $meta->add_method( 'DESTROY' => $destroy );
    }
    $immutable_options{inline_destructor} = 0;

    $self->{immutable_options} = \%immutable_options;
    $meta->make_immutable(%immutable_options);
    $self->_set_initialized_class;
}

sub mapping {
    my ( $self, $hashref_data, $uow ) = @_;

    return unless $hashref_data;

    my $constructor = $self->constructor->name;
    my $type = $self->constructor->arg_type;

    my $param;
    for my $prop_name ( $self->attributes->property_names ) {
        my $prop = $self->attributes->property_info($prop_name);
        my $name = $prop->name || $prop_name;
        my $val = $hashref_data->{$name};

        if( $prop->type eq 'relation' and defined $val ) {
            if( $prop->is_multi ) {
                $val = [ map { $prop->mapper->mapping($_, $uow) } @$val ];
            }
            else {
                $val = $prop->mapper->mapping($val, $uow);
            }
        }

        if( $type eq 'HASH' or $type eq 'HASHREF' ) {
            $param ||= +{};
            $param->{$prop_name} = $val;
        }
        elsif( $type eq 'ARRAY' or $type eq 'ARRAYREF' ) {
            $param ||= +[];
            push @$param, $val;
        }

        $uow->change_checker->regist($val) if $uow and ref $val;
    }

    my $obj = $self->mapped_class->${constructor}(
          $type eq 'HASH' ? %$param
        : ( $type eq 'HASHREF' || $type eq 'ARRAYREF' ) ? $param
        : ( $type eq 'ARRAY' ) ? @$param
        :                        undef
    );

    $obj->__mapper__->initialize; # initialized mapper
    return $uow ? $uow->add_storage_object($obj) : $obj;
}

sub find {
    my $self = shift;
    my $where = shift;
    my @where = @$where;
    push @where, @{$self->default_condition};
    my $it = $self->select->where(@where)->execute;
    return unless $it;
    return $self->mapping($it->next || undef, @_);
}

sub load_properties {
    my $self = shift;

    my @column;
    for my $prop_name ( $self->attributes->property_names ) {
        my $prop = $self->attributes->property_info($prop_name);
        next unless $prop->type eq 'column' and !$prop->lazy;
        push @column, $prop->{isa};
    }
    return @column;
}

sub select {
    my $self = shift;
    my @column = @_;
    push @column, $self->load_properties unless @column;
    return $self->table->select->column(@column);
}

sub insert {
    my $self = shift;
    my %data = @_;
    return $self->table->insert(%data)->execute;
}

sub update {
    my $self = shift;
    my ( $data, $cond ) = @_;
    return map { $_->execute } $self->table->update($data, $cond);
}

sub delete {
    my $self = shift;
    my @where = @_;
    return map { $_->execute } $self->table->delete(@where);
}

sub get_unique_condition {
    my ( $self, $id ) = @_;

    my ( $type, @cond ) = $self->table->get_unique_condition($id);
    confess "condition is not unique." unless @cond;
    return $self->create_cache_key($type, @cond), @cond;
}

sub create_cache_key {
    my ( $self, $cond_type, @cond ) = @_;
    my $key
        = $cond_type
        ? $cond_type . '#'
            . join( '&', map { $_->[0]->name . '=' . $_->[2] } @cond )
        : join( '&', map { $_->[0]->name . '=' . $_->[2] } @cond );

    return md5_hex( $self->mapped_class . '@' . $key );
}

sub primary_cache_key {
    my ( $self, $result ) = @_;

    my @ids;
    for my $key ( @{ $self->table->primary_key } ) {
        push @ids,
            $key . '='
            . ( defined $result->{$key} ? $result->{$key} : 'NULL' );
    }

    return md5_hex( $self->mapped_class . '@' . join( '&', @ids ) );
}

sub unique_cache_keys {
    my ( $self, $result ) = @_;
    my @keys;
    for my $uniq ( @{ $self->table->unique_key } ) {
        my $name = $uniq->[0];
        my $keys = $uniq->[1];
        my @uniq_ids;
        for my $key (@$keys) {
            push @uniq_ids,
                $key . '='
                . ( defined $result->{$key} ? $result->{$key} : 'NULL' );
        }
        push @keys,
            md5_hex( $self->mapped_class . '@'
                . $name . '#'
                . join( '&', @uniq_ids ) );
    }

    return @keys;
}

1;

__END__

=head1 NAME

DBIx::ObjectMapper::Mapper - map the metadata to a class.

=head1 DESCRIPTION

=head1 SYNOPSIS

  my $mapped_artist = DBIx::ObjectMapper::Mapper->new(
     $meta->t('artist') => 'My::Artist',
     attributes => {
         include    => [],
         exclude    => [],
         prefix     => '',
         properties => +{
             isa               => undef,
             lazy              => 0,
             validation        => 0,
         }
     },
     accessors => +{
         auto       => 0,
         exclude    => [],
         do_replace => 0,
     },
     constructor => +{
         name     => 'new',
         arg_type => 'HASHREF',
         auto     => 0,
     },
     default_condition => [],
     default_value     => {},
 );

=head1 METHODS

=head2 new(%config)

=head3 attributes

=head3 accessors

=head3 constructor

=head3 default_condition

=head2 is_initialized

=head2 mapping

=head2 find

=head2 get_unique_condition

=head2 create_cache_key

=head2 primary_cache_key

=head2 unique_cache_keys


=head1 AUTHOR

Eisuke Oishi

=head1 COPYRIGHT

Copyright 2009 Eisuke Oishi

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.
