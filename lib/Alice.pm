package Alice;

use AnyEvent;
use AnyEvent::Strict;
use AnyEvent::Log;

use Any::Moose;
use Text::MicroTemplate::File;
use Digest::MD5 qw/md5_hex/;
use List::Util qw/first/;
use List::MoreUtils qw/any/;
use AnyEvent::IRC::Util qw/filter_colors/;
use IRC::Formatting::HTML qw/html_to_irc/;
use Encode;

use Alice::Window;
use Alice::InfoWindow;
use Alice::HTTPD;
use Alice::IRC;
use Alice::Config;
use Alice::Tabset;
use Alice::MessageBuffer;
use Alice::MessageStore;

our $VERSION = '0.19';

with 'Alice::Role::IRCCommands';

has config => (
  is       => 'rw',
  isa      => 'Alice::Config',
);

has _ircs => (
  is      => 'rw',
  isa     => 'ArrayRef',
  default => sub {[]},
);

sub ircs {@{$_[0]->_ircs}}
sub add_irc {push @{$_[0]->_ircs}, $_[1]}
sub has_irc {$_[0]->get_irc($_[1])}
sub get_irc {first {$_->alias eq $_[1]} $_[0]->ircs}
sub remove_irc {$_[0]->_ircs([ grep { $_->alias ne $_[1] } $_[0]->ircs])}
sub irc_aliases {map {$_->alias} $_[0]->ircs}
sub connected_ircs {grep {$_->is_connected} $_[0]->ircs}

has httpd => (
  is      => 'rw',
  isa     => 'Alice::HTTPD',
  lazy    => 1,
  default => sub {
    Alice::HTTPD->new(app => shift);
  },
);

has streams => (
  is      => 'rw',
  isa     => 'ArrayRef',
  default => sub {[]},
);

sub add_stream {unshift @{shift->streams}, @_}
sub no_streams {@{$_[0]->streams} == 0}
sub stream_count {scalar @{$_[0]->streams}}

has message_store => (
  is      => 'ro',
  lazy    => 1,
  default => sub {
    my $self = shift;
    my $buffer = $self->config->path."/buffer.db";
    if (! -e  $buffer) {
      require File::Copy;
      File::Copy::copy($self->config->assetdir."/buffer.db", $buffer);
    }
    Alice::MessageStore->new(dsn => ["dbi:SQLite:dbname=$buffer", "", ""]);
  }
);

has _windows => (
  is        => 'rw',
  isa       => 'ArrayRef',
  default   => sub {[]},
);

sub windows {@{$_[0]->_windows}}
sub add_window {push @{$_[0]->_windows}, $_[1]}
sub has_window {$_[0]->get_window($_[1])}
sub get_window {first {$_->id eq $_[1]} $_[0]->windows}
sub remove_window {$_[0]->_windows([grep {$_->id ne $_[1]} $_[0]->windows])}
sub window_ids {map {$_->id} $_[0]->windows}

has 'template' => (
  is => 'ro',
  isa => 'Text::MicroTemplate::File',
  lazy => 1,
  default => sub {
    my $self = shift;
    Text::MicroTemplate::File->new(
      include_path => $self->config->assetdir . '/templates',
      cache        => 2,
    );
  },
);

has 'info_window' => (
  is => 'ro',
  isa => 'Alice::InfoWindow',
  lazy => 1,
  default => sub {
    my $self = shift;
    my $id = $self->_build_window_id("info", "info");
    my $info = Alice::InfoWindow->new(
      id       => $id,
      buffer   => $self->_build_window_buffer($id),
      app      => $self,
    );
    $self->add_window($info);
    return $info;
  }
);

has 'user' => (
  is => 'ro',
  default => $ENV{USER}
);

sub BUILDARGS {
  my ($class, %options) = @_;

  my $self = {};

  for (qw/template user httpd message_store/) {
    if (exists $options{$_}) {
      $self->{$_} = $options{$_};
      delete $options{$_};
    }
  }

  $self->{config} = Alice::Config->new(
    %options,
    callback => sub {$self->{config}->merge(\%options)}
  );

  return $self;
}

sub run {
  my $self = shift;

  # wait for config to finish loading
  my $w; $w = AE::idle sub {
    return unless $self->config->{loaded};
    undef $w;
    $self->init;
  };
}

sub init {
  my $self = shift;
  $self->commands;
  $self->info_window;
  $self->template;
  $self->httpd;

  $self->add_irc_server($_, $self->config->servers->{$_})
    for keys %{$self->config->servers};
}

sub init_shutdown {
  my ($self, $cb, $msg) = @_;

  $self->alert("Alice server is shutting down");
  $_->disconnect($msg) for $self->connected_ircs;

  my ($w, $t);
  my $shutdown = sub {
    undef $w;
    undef $t;
    $self->shutdown;
    $cb->() if $cb;
  };

  $w = AE::idle sub {$shutdown->() unless $self->connected_ircs};
  $t = AE::timer 3, 0, $shutdown;
}

sub shutdown {
  my $self = shift;

  $self->_ircs([]);
  $_->close for @{$self->streams};
  $self->streams([]);
}

sub reload_commands {
  my $self = shift;
  $self->commands->reload_handlers;
}

sub tab_order {
  my ($self, $window_ids) = @_;
  my $order = [];
  for my $count (0 .. scalar @$window_ids - 1) {
    if (my $window = $self->get_window($window_ids->[$count])) {
      next unless $window->is_channel
           and $self->config->servers->{$window->irc->alias};
      push @$order, $window->id;
    }
  }
  $self->config->order($order);
  $self->config->write;
}

sub find_window {
  my ($self, $title, $connection) = @_;
  return $self->info_window if $title eq "info";
  my $id = $self->_build_window_id($title, $connection->alias);
  if (my $window = $self->get_window($id)) {
    return $window;
  }
}

sub alert {
  my ($self, $message) = @_;
  return unless $message;
  $self->broadcast({
    type => "action",
    event => "alert",
    body => $message,
  });
}

sub create_window {
  my ($self, $title, $connection) = @_;
  my $id = $self->_build_window_id($title, $connection->alias);
  my $window = Alice::Window->new(
    title    => $title,
    type     => $connection->is_channel($title) ? "channel" : "privmsg",
    irc      => $connection,
    app      => $self,
    id       => $id,
    buffer   => $self->_build_window_buffer($id),
  );
  $self->add_window($window);
  return $window;
}

sub _build_window_buffer {
  my ($self, $id) = @_;
  Alice::MessageBuffer->new(
    id => $id,
    store => $self->message_store,
  );
}

sub _build_window_id {
  my ($self, $title, $session) = @_;
  md5_hex(encode_utf8(lc $self->user."-$title-$session"));
}

sub find_or_create_window {
  my ($self, $title, $connection) = @_;
  return $self->info_window if $title eq "info";

  if (my $window = $self->find_window($title, $connection)) {
    return $window;
  }

  $self->create_window($title, $connection);
}

sub sorted_windows {
  my $self = shift;

  my %o = map {
    $self->config->order->[$_] => sprintf "%02d", $_ + 2
  } (0 .. @{$self->config->order} - 1);

  $o{$self->info_window->id} = "01";
  my $prefix = scalar @{$self->config->order} + 1;

  map  {$_->[1]}
  sort {$a->[0] cmp $b->[0]}
  map  {[($o{$_->id} || $o{$_->title} || $prefix.$_->sort_name), $_]}
       $self->windows;
}

sub close_window {
  my ($self, $window) = @_;
  $self->broadcast($window->close_action);
  AE::log debug => "sending a request to close a tab: " . $window->title;
  $self->remove_window($window->id) if $window->type ne "info";
}

sub add_irc_server {
  my ($self, $name, $config) = @_;
  $self->config->servers->{$name} = $config;
  my $irc = Alice::IRC->new(
    app    => $self,
    alias  => $name
  );
  $self->add_irc($irc);
}

sub reload_config {
  my ($self, $new_config) = @_;

  my %prev = map {$_ => $self->config->servers->{$_}{ircname} || ""}
             keys %{ $self->config->servers };

  if ($new_config) {
    $self->config->merge($new_config);
    $self->config->write;
  }
  
  for my $network (keys %{$self->config->servers}) {
    my $config = $self->config->servers->{$network};
    if (!$self->has_irc($network)) {
      $self->add_irc_server($network, $config);
    }
    else {
      my $irc = $self->get_irc($network);
      $config->{ircname} ||= "";
      if ($config->{ircname} ne $prev{$network}) {
        $irc->update_realname($config->{ircname});
      }
      $irc->config($config);
    }
  }
  for my $irc ($self->ircs) {
    if (!$self->config->servers->{$irc->alias}) {
      $self->remove_window($_->id) for $irc->windows;
      $irc->remove;
    }
  }
}

sub send_announcement {
  my ($self, $window, $body) = @_;
  
  my $message = $window->format_announcement($body);
  $self->broadcast($message);
}

sub send_topic {
  my ($self, $window) = @_;
  my $message = $window->format_topic;
  $self->broadcast($message);
}

sub format_info {
  my ($self, $session, $body, %options) = @_;
  $self->info_window->format_message($session, $body, %options);
}

sub send_message {
  my ($self, $window, $nick, $body) = @_;

  my $connection = $self->get_irc($window->network);
  my %options = (
    mono => $self->is_monospace_nick($nick),
    self => $connection->nick eq $nick,
    avatar => $connection->nick_avatar($nick) || "",
    highlight => $self->is_highlight($connection->nick, $body),
  );

  my $message = $window->format_message($nick, $body, %options);
  $self->broadcast($message);
}

sub broadcast {
  my ($self, @messages) = @_;
  return if $self->no_streams or !@messages;
  for my $stream (@{$self->streams}) {
    $stream->send(\@messages);
  }
}

sub ping {
  my $self = shift;
  return if $self->no_streams;
  $_->ping for grep {$_->is_xhr} @{$self->streams};
}

sub update_stream {
  my ($self, $stream, $req) = @_;

  my $limit = $req->param('limit') || 500;
  my $max   = $req->param('max')   || $self->message_store->msgid;
  my $min   = $req->param('min')   || 0;

  AE::log debug => "sending stream update";

  my @windows = $self->windows;

  if (my $id = $req->param('tab')) {
    if (my $active = $self->get_window($id)) {
      @windows = grep {$_->id ne $id} @windows;
      unshift @windows, $active;
    }
  }

  for my $window (@windows) {
    AE::log debug => "updating stream for ".$window->title;
    $self->update_window($stream, $window, $max, $min, $limit);
  }
}

sub update_window {
  my ($self, $stream, $window, $max, $min, $limit, $total) = @_;
  $total ||= 0;

  $window->buffer->messages($max, $min, 50, sub {
    my $msgs = shift;
    return unless @$msgs;

    $stream->send([{
      window => $window->serialized,
      type   => "chunk",
      nicks  => $window->all_nicks,
      range  => [$msgs->[0]{msgid}, $msgs->[-1]{msgid}],
      html   => join "", map {$_->{html}} @$msgs,
    }]);

    if (@$msgs == 50 and $total <= $limit) {
      $max = $msgs->[0]->{msgid};
      my $t; $t = AE::timer 0.2, 0, sub {
        undef $t;
        $self->update_window($stream, $window, $max, $min, $limit, $total + scalar @$msgs);
      };
    }
  });
}

sub handle_message {
  my ($self, $message) = @_;

  if (my $window = $self->get_window($message->{source})) {
    $message->{msg} = html_to_irc($message->{msg}) if $message->{html};

    for (split /\n/, $message->{msg}) {
      $self->irc_command($window, $_) if length $_;
    }
  }
}

sub send_highlight {
  my ($self, $nick, $body, $source) = @_;
  my $message = $self->info_window->format_message($nick, $body, self => 1, source => $source);
  $self->broadcast($message);
}

sub purge_disconnects {
  my ($self) = @_;
  AE::log debug => "removing broken streams";
  $self->streams([grep {!$_->closed} @{$self->streams}]);
}

sub render {
  my ($self, $template, @data) = @_;
  $self->template->render_file("$template.html", $self, @data)->as_string;
}

sub is_highlight {
  my ($self, $own_nick, $body) = @_;
  $body = filter_colors $body;
  any {$body =~ /(?:\W|^)\Q$_\E(?:\W|$)/i }
      (@{$self->config->highlights}, $own_nick);
}

sub is_monospace_nick {
  my ($self, $nick) = @_;
  any {$_ eq $nick} @{$self->config->monospace_nicks};
}

sub is_ignore {
  my $self = shift;
  return $self->config->is_ignore(@_);
}

sub add_ignore {
  my $self = shift;
  return $self->config->add_ignore(@_);
}

sub remove_ignore {
  my $self = shift;
  return $self->config->remove_ignore(@_);
}

sub ignores {
  my $self = shift;
  return $self->config->ignores(@_);
}

sub static_url {
  my ($self, $file) = @_;
  return $self->config->static_prefix . $file;
}

sub auth_enabled {
  my $self = shift;

  # cache it
  if (!defined $self->{_auth_enabled}) {
    $self->{_auth_enabled} = ($self->config->auth
              and ref $self->config->auth eq 'HASH'
              and $self->config->auth->{user}
              and $self->config->auth->{pass});
  }

  return $self->{_auth_enabled};
}

sub authenticate {
  my ($self, $user, $pass) = @_;
  $user ||= "";
  $pass ||= "";
  if ($self->auth_enabled) {
    return ($self->config->auth->{user} eq $user
       and $self->config->auth->{pass} eq $pass);
  }
  return 1;
}

sub set_away {
  my ($self, $message) = @_;
  my @args = (defined $message ? (AWAY => $message) : "AWAY");
  $_->send_srv(@args) for $self->connected_ircs;
}

sub tabsets {
  my $self = shift;
  map {
    Alice::Tabset->new(
      name => $_,
      windows => $self->config->tabsets->{$_},
    );
  } sort keys %{$self->config->tabsets};
}

__PACKAGE__->meta->make_immutable;
1;

=pod

=head1 NAME

Alice - an Altogether Lovely Internet Chatting Experience

=head1 SYNPOSIS

    my $app = Alice->new;
    $app->run;

=head1 DESCRIPTION

This is an overview of the Alice class. If you are curious
about running and/or using alice please read the L<Alice::Readme>.

=head2 CONSTRUCTOR

=over 4

=item Alice->new(%options)

Alice's contructor takes these options:

=item user => $username

This can be a unique name for this Alice instance, if none is
provided it will simply use $ENV{USER}.

=back

=head2 METHODS

=over 4

=item run

This will start the Alice. It will start up the HTTP server and
begin connecting to IRC servers that are set to autoconnect.

=item handle_command ($command_string, $window)

Take a string and matches it to the correct action as defined by
L<Alice::Command>. A source L<Alice::Window> must also
be provided.

=item find_window ($title, $connection)

Takes a window title and Alice::IRC object. It will attempt
to find a matching window and return undef if none is found.

=item alert ($alertstring)

Send a message to all connected clients. It will show up as a red
line in their currently focused window.

=item create_window ($title, $connection)

This will create a new L<Alice::Window> object associated
with the provided L<Alice::IRC> object.

=item find_or_create_window ($title, $connection)

This will attempt to find an existing window with the provided
title and connection. If no window is found it will create
a new one.

=item windows

Returns a list of all the L<Alice::Window>s.

=item sorted_windows

Returns a list of L<Alice::Windows> sorted in the order
defined by the user's config.

=item close_window ($window)

Takes an L<Alice::Window> object to be closed. It will
part if it is a channel and send the required messages to the
client to close the tab.

=item ircs

Returns a list of all the L<Alice::IRC>s.

=item connected_ircs

Returns a list of all the connected L<Alice::IRC>s.

=item config

Returns this instance's L<Alice::Config> object.

=back

=cut

