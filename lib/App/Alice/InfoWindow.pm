package App::Alice::InfoWindow;

use Moose;
use Encode;
use IRC::Formatting::HTML;

extends 'App::Alice::Window';

has '+is_channel' => (lazy => 0, default => 0);
has '+id' => (default => 'info');
has '+title' => (required => 0, default => 'info');
has '+irc' => (required => 0);
has '+session' => ( isa => 'Undef', default => undef);
has 'topic' => (is => 'ro', isa => 'HashRef', default => sub {{Value => 'info'}});
has '+buffersize' => (default => 300);
has '+type' => (lazy => 0, default => 'info');

sub render_message {
  my ($self, $from, $body, $highlight) = @_;
  $highlight = 0 unless $highlight;
  my $html = IRC::Formatting::HTML->formatted_string_to_html($body);
  my $message = {
    type   => "message",
    event  => "say",
    nick   => $from,
    window => $self->serialized,
    body   => $body,
    self   => $highlight,
    html   => $html,
    msgid  => $self->next_msgid,
  };
  my $full_html = '';
  $self->tt->process("message.tt", $message, \$full_html);
  $message->{full_html} = $full_html;
  $self->add_message($message);
  return $message;
}

__PACKAGE__->meta->make_immutable;
1;