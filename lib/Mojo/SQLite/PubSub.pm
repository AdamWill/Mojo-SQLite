package Mojo::SQLite::PubSub;
use Mojo::Base 'Mojo::EventEmitter';

use Mojo::JSON qw(from_json to_json);
use Scalar::Util 'weaken';

our $VERSION = '1.001';

has [qw(poll_interval sqlite)];

sub DESTROY { shift->_cleanup }

sub json { ++$_[0]{json}{$_[1]} and return $_[0] }

sub listen {
  my ($self, $name, $cb) = @_;
  $self->_db->listen($name) unless @{$self->{chans}{$name} ||= []};
  push @{$self->{chans}{$name}}, $cb;
  return $cb;
}

sub notify { $_[0]->_db->notify(_json(@_)) and return $_[0] }

sub unlisten {
  my ($self, $name, $cb) = @_;
  my $chan = $self->{chans}{$name};
  @$chan = $cb ? grep { $cb ne $_ } @$chan : ();
  $self->_db->unlisten($name) and delete $self->{chans}{$name} unless @$chan;
  return $self;
}

sub _cleanup {
  my $self = shift;
  $self->{db}->_unwatch;
  delete @$self{qw(chans db pid)};
}

sub _db {
  my $self = shift;

  # Fork-safety
  $self->_cleanup unless ($self->{pid} //= $$) eq $$;

  return $self->{db} if $self->{db};

  my $db = $self->{db} = $self->sqlite->db;
  $db->notification_poll_interval($self->poll_interval) if defined $self->poll_interval;
  weaken $db->{sqlite};
  weaken $self;
  $db->on(
    notification => sub {
      my ($db, $name, $payload) = @_;
      $payload = eval { from_json $payload } if $self->{json}{$name};
      for my $cb (@{$self->{chans}{$name}}) { $self->$cb($payload) }
    }
  );
  $db->once(
    close => sub {
      local $@;
      delete $self->{db};
      eval { $self->_db };
    }
  );
  $db->listen($_) for keys %{$self->{chans}}, 'mojo.pubsub';
  $self->emit(reconnect => $db);

  return $db;
}

sub _json { $_[1], $_[0]{json}{$_[1]} ? to_json $_[2] : $_[2] }

1;

=encoding utf8

=head1 NAME

Mojo::SQLite::PubSub - Publish/Subscribe

=head1 SYNOPSIS

  use Mojo::SQLite::PubSub;

  my $pubsub = Mojo::SQLite::PubSub->new(sqlite => $sql);
  my $cb = $pubsub->listen(foo => sub {
    my ($pubsub, $payload) = @_;
    say "Received: $payload";
  });
  $pubsub->notify(foo => 'I ♥ SQLite!');
  $pubsub->unlisten(foo => $cb);

=head1 DESCRIPTION

L<Mojo::SQLite::PubSub> is a scalable implementation of the publish/subscribe
pattern used by L<Mojo::SQLite>. It allows many consumers to share the same
database connection, to avoid many common scalability problems. As SQLite has
no notification system, it is implemented via event loop polling in
L<Mojo::SQLite::Database>, using automatically created tables prefixed with
C<mojo_pubsub>.

All subscriptions will be reset automatically and the database connection
re-established if a new process has been forked, this allows multiple processes
to share the same L<Mojo::SQLite::PubSub> object safely.

=head1 EVENTS

L<Mojo::SQLite::PubSub> inherits all events from L<Mojo::EventEmitter> and can
emit the following new ones.

=head2 reconnect

  $pubsub->on(reconnect => sub {
    my ($pubsub, $db) = @_;
    ...
  });

Emitted after switching to a new database connection for sending and receiving
notifications.

=head1 ATTRIBUTES

L<Mojo::SQLite::PubSub> implements the following attributes.

=head2 poll_interval

  my $interval = $pubsub->poll_interval;
  $pubsub      = $pubsub->poll_interval(0.25);

Interval in seconds to poll for notifications from L</"notify">, passed along
to L<Mojo::SQLite::Database/"notification_poll_interval">. Note that lower
values will increase pubsub responsiveness as well as CPU utilization.

=head2 sqlite

  my $sql = $pubsub->sqlite;
  $pubsub = $pubsub->sqlite(Mojo::SQLite->new);

L<Mojo::SQLite> object this publish/subscribe container belongs to.

=head1 METHODS

L<Mojo::SQLite::PubSub> inherits all methods from L<Mojo::EventEmitter> and
implements the following new ones.

=head2 json

  $pubsub = $pubsub->json('foo');

Activate automatic JSON encoding and decoding with L<Mojo::JSON/"to_json"> and
L<Mojo::JSON/"from_json"> for a channel.

  # Send and receive data structures
  $pubsub->json('foo')->listen(foo => sub {
    my ($pubsub, $payload) = @_;
    say $payload->{bar};
  });
  $pubsub->notify(foo => {bar => 'I ♥ SQLite!'});

=head2 listen

  my $cb = $pubsub->listen(foo => sub {...});

Subscribe to a channel, there is no limit on how many subscribers a channel can
have. Automatic decoding of JSON text to Perl values can be activated with
L</"json">.

  # Subscribe to the same channel twice
  $pubsub->listen(foo => sub {
    my ($pubsub, $payload) = @_;
    say "One: $payload";
  });
  $pubsub->listen(foo => sub {
    my ($pubsub, $payload) = @_;
    say "Two: $payload";
  });

=head2 notify

  $pubsub = $pubsub->notify('foo');
  $pubsub = $pubsub->notify(foo => 'I ♥ SQLite!');
  $pubsub = $pubsub->notify(foo => {bar => 'baz'});

Notify a channel. Automatic encoding of Perl values to JSON text can be
activated with L</"json">.

=head2 unlisten

  $pubsub = $pubsub->unlisten('foo');
  $pubsub = $pubsub->unlisten(foo => $cb);

Unsubscribe from a channel.

=head1 SEE ALSO

L<Mojo::SQLite>, L<Mojo::SQLite::Database>
