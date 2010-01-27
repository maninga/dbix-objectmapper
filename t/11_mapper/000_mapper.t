use strict;
use warnings;
use Test::More;
use Test::Exception;

use Data::ObjectMapper::Metadata;
use Data::ObjectMapper::Engine::DBI;
use Data::ObjectMapper::Mapper;

use Scalar::Util;
use FindBin;
use File::Spec;
use lib File::Spec->catfile( $FindBin::Bin, 'lib' );

my $engine = Data::ObjectMapper::Engine::DBI->new({
    dsn => 'DBI:SQLite:',
    username => '',
    password => '',
    on_connect_do => [
        q{ CREATE TABLE artist (id integer primary key, firstname text not null, lastname text not null)}
    ]
});

my $meta = Data::ObjectMapper::Metadata->new( engine => $engine );
my $artist_table = $meta->table( artist => 'autoload' );

sub is_same_addr($$) {
    is Scalar::Util::refaddr($_[0]), Scalar::Util::refaddr($_[1]);
}

{ # map defined class
    my $mapped_class = 'MyTest::Basic::Artist';
    ok my $mapper = Data::ObjectMapper::Mapper->new(
        $artist_table => $mapped_class
    );
    ok( Data::ObjectMapper::Mapper->is_initialized($mapped_class) );
    ok $mapped_class->can('__class_mapper__');
    is_same_addr $mapper, $mapped_class->__class_mapper__;

    for my $c ( @{$artist_table->columns} ) {
        is_deeply $mapper->attributes->property($c->name)->{isa}, $c;
    }
};

{ # map auto generate class
    my $mapped_class = 'MyTest::Basic::ArtistAuto';
    ok my $mapper = Data::ObjectMapper::Mapper->new(
        $meta->t('artist') => $mapped_class,
        accessors   => +{ auto => 1 },
        constructor => +{ auto => 1 },
    );

    ok( Data::ObjectMapper::Mapper->is_initialized($mapped_class) );
    ok $mapped_class->can('firstname');
    ok $mapped_class->can('lastname');
    ok $mapped_class->can('id');

    ok my $obj = $mapped_class->new(
        { id => 1, firstname => 'f', lastname => 'l' } );
    is $obj->firstname, 'f';
    is $obj->lastname, 'l';
    is $obj->id, 1;
};

{ # attribute prefix
    my $mapped_class = 'MyTest::Basic::ArtistAutoPrefix';
    ok my $mapper = Data::ObjectMapper::Mapper->new(
        $meta->t('artist') => $mapped_class,
        accessors   => +{ auto => 1 },
        constructor => +{ auto => 1 },
        attributes  => +{ prefix => '_' },
    );

    ok (Data::ObjectMapper::Mapper->is_initialized($mapped_class));
    ok $mapped_class->can('_firstname');
    ok $mapped_class->can('_lastname');
    ok $mapped_class->can('_id');
    ok !$mapped_class->can('firstname');
    ok !$mapped_class->can('lastname');
    ok !$mapped_class->can('id');

    ok my $obj = $mapped_class->new(
        { _id => 1, _firstname => 'f', _lastname => 'l' } );
    is $obj->_firstname, 'f';
    is $obj->_lastname, 'l';
    is $obj->_id, 1;

#    dies_ok {
#        $mapped_class->new({ id => 1, firstname => 'f', lastname => 'l' } );
#    };

};

{ # attribute include option
    my $mapped_class = 'MyTest::Basic::ArtistAutoInclude';
    ok my $mapper = Data::ObjectMapper::Mapper->new(
        $meta->t('artist') => $mapped_class,
        accessors   => +{ auto => 1 },
        constructor => +{ auto => 1 },
        attributes  => +{
            include => +[qw(id lastname)],
        }
    );

    ok $mapped_class->can('id');
    ok $mapped_class->can('lastname');
    ok !$mapped_class->can('firstname');

    ok my $obj = $mapped_class->new({ id => 1, lastname => 'l' } );
    is $obj->lastname, 'l';
    is $obj->id, 1;

#    dies_ok {
#        $mapped_class->new({ id => 1, firstname => 'f', lastname => 'l' } );
#    };
};

{ # attribute exclue option
    my $mapped_class = 'MyTest::Basic::ArtistAutoExclude';
    ok my $mapper = Data::ObjectMapper::Mapper->new(
        $meta->t('artist') => $mapped_class,
        accessors   => +{ auto => 1 },
        constructor => +{ auto => 1 },
        attributes  => +{
            exclude => +[qw(lastname)],
        }
    );

    ok $mapped_class->can('firstname');
    ok $mapped_class->can('id');
    ok !$mapped_class->can('lastname');

    ok my $obj = $mapped_class->new(
        { id => 1, firstname => 'f' } );
    is $obj->firstname, 'f';
    is $obj->id, 1;

#    dies_ok {
#        $mapped_class->new({ id => 1, firstname => 'f', lastname => 'l' } );
#    };
};

{ # attribute include and exclude  option
    my $mapped_class = 'MyTest::Basic::ArtistAutoIncludeExclude';
    ok my $mapper = Data::ObjectMapper::Mapper->new(
        $meta->t('artist') => $mapped_class,
        accessors   => +{ auto => 1 },
        constructor => +{ auto => 1 },
        attributes  => +{
            include => +[qw(firstname lastname)],
            exclude => +[qw(lastname)],
        }
    );

    ok $mapped_class->can('firstname');
    ok $mapped_class->can('id');
    ok !$mapped_class->can('lastname');

    ok my $obj = $mapped_class->new( { firstname => 'f' } );
    is $obj->firstname, 'f';

#    dies_ok {
#        $mapped_class->new({ id => 1, firstname => 'f', lastname => 'l' } );
#    };
};


{ # map not exsits class
    my $mapped_class = 'MyTest::Basic::ArtistAutoNotExists';
    dies_ok {
        my $mapper = Data::ObjectMapper::Mapper->new(
            $meta->t('artist') => $mapped_class,
        );
    };
};

{ # accessor only
    my $mapped_class = 'MyTest::AO::Artist';
    ok my $mapper = Data::ObjectMapper::Mapper->new(
        $meta->t('artist') => $mapped_class,
        constructor => +{ auto => 1 },
    );

    ok $mapped_class->can('new');
    ok $mapped_class->can('firstname');
    ok $mapped_class->can('lastname');
    ok $mapped_class->can('fullname');

    ok my $obj = $mapped_class->new(
        { id => 1, firstname => 'f', lastname => 'l' } );
    is $obj->id, 1;
    is $obj->firstname, 'f';
    is $obj->lastname, 'l';
};

{ # constructor only
    my $mapped_class = 'MyTest::CO::Artist';
    ok my $mapper = Data::ObjectMapper::Mapper->new(
        $meta->t('artist') => $mapped_class,
        accessors   => +{ auto => 1 },
        constructor => { arg_type => 'ARRAY' },
    );

    ok $mapped_class->can('new');
    ok $mapped_class->can('firstname');
    ok $mapped_class->can('lastname');

    ok my $obj = $mapped_class->new( 1, 'f', 'l' );
    is $obj->id, 1;
    is $obj->firstname, 'f';
    is $obj->lastname, 'l';
};

{ # array contructor argument
    my $mapped_class = 'MyTest::Basic::ArtistArray';
    ok my $mapper = Data::ObjectMapper::Mapper->new(
        $meta->t('artist') => $mapped_class,
        constructor => { arg_type => 'ARRAY' },
        attributes  => {
            properties  => [
                {
                    isa => $meta->t('artist')->c('lastname'),
                },
                {
                    isa => $meta->t('artist')->c('firstname'),
                },
                {
                    isa => $meta->t('artist')->c('id'),
                },
            ],
        }
    );

    my $obj = $mapper->mapping({
        id => 10,
        firstname => 'firstname',
        lastname => 'lastname',
    });

    is $obj->firstname, 'firstname';
    is $obj->lastname, 'lastname';
    is $obj->id, 10;

    $mapper->dissolve;
};

{ # not include primary key
    my $mapped_class = 'MyTest::Basic::ArtistArray';

    dies_ok {
        ok my $mapper = Data::ObjectMapper::Mapper->new(
            $meta->t('artist') => $mapped_class,
            constructor => { arg_type => 'ARRAY' },
            attributes  => {
                properties  => [
                    {
                        isa => $meta->t('artist')->c('lastname'),
                    },
                    {
                        isa => $meta->t('artist')->c('firstname'),
                    },
                ],
            }
        );
    };
};


# XXXXX join(relation)
# XXXXX table is query

done_testing;

__END__
