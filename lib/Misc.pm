package Misc;

# Общие модули - синтаксис, кодировки итд
use 5.018;
use strict;
use warnings;
use utf8;
use open qw (:std :utf8);

# Модули для работы приложения
use Math::Random::Secure qw (irand);
# Чтобы "уж точно" использовать hiredis-биндинги, загрузим этот модуль перед Mojo::Redis
use Protocol::Redis::XS;
use Mojo::Redis;
use Mojo::IOLoop;
use Mojo::IOLoop::Signal;
use Mojo::Log;
use Data::Dumper;

use Conf qw (LoadConf);

use version; our $VERSION = qw (1.0);
use Exporter qw (import);
our @EXPORT_OK = qw (RunMisc);

my $c = LoadConf ();

my $loglevel = $c->{'loglevel'} // 'info';
my $fwd_cnt = $c->{'forward_max'} // 5;
my $logfile;
my $log;

if (defined $c->{'log'}) {
	$logfile = $c->{'log'};
} elsif (defined $c->{'debug_log'}) {
	$logfile = $c->{'debug_log'};
}

if (defined $logfile) {
	$log = Mojo::Log->new (path => $logfile, level => $loglevel);
} else {
	$log = Mojo::Log->new (path => '/dev/null', level => 'fatal');
}

# Основной парсер
my $parse_message = sub {
	my $self = shift;
	my $m = shift;
	my $answer = $m;
	$answer->{from} = 'misc';

	if (defined $answer->{misc}) {
		unless (defined $answer->{misc}->{fwd_cnt}) {
			$answer->{misc}->{fwd_cnt} = 1;
		} else {
			if ($answer->{misc}->{fwd_cnt} > $fwd_cnt) {
				$log->error ('Forward loop detected, discarding message.');
				$log->debug (Dumper $m);
				return;
			} else {
				$answer->{misc}->{fwd_cnt}++;
			}
		}

		unless (defined $answer->{misc}->{answer}) {
			$answer->{misc}->{answer} = 1;
		}

		unless (defined $answer->{misc}->{csign}) {
			$answer->{misc}->{csign} = '!';
		}
	} else {
		$answer->{misc}->{answer} = 1;
		$answer->{misc}->{csign} = '!';
		$answer->{misc}->{msg_format} = 0;
	}

	# Если сообщение не попало ни под один шаблон, оно отправляется к craniac-у
	my $send_to = 'craniac';

	$log->debug ('[DEBUG] Incoming message ' . Dumper($m));

	# Пробуем найти команды. Сообщения, начинающиеся с $answer->{misc}->{csign}
	if (substr ($m->{message}, 0, 1) eq $answer->{misc}->{csign}) {
		my $done = 0;
		my @phrases_cmd = qw (friday пятница proverb пословица fortune фортунка f ф karma карма);

		while (my $cmd = pop @phrases_cmd) {
			if (substr ($m->{message}, 1) eq $cmd) {
				$send_to = 'phrases';
				$done = 1;
				last;
			}
		}

		unless ($done) {
			my @webapp_cmd = qw (buni anek анек анекдот cat кис drink праздник fox лис frog лягушка horse лошадь лошадка
								monkeyuser rabbit bunny кролик snail улитка owl сова сыч xkcd tits boobs tities boobies
								сиси сисечки butt booty ass попа попка);

			while (my $cmd = pop @webapp_cmd) {
				if (substr ($m->{message}, 1) eq $cmd) {
					$send_to = 'webapp';
					$done = 1;
					last;
				}
			}
		}

		unless ($done) {
			if (substr ($m->{message}, 1, 2) eq 'w ' || substr ($m->{message}, 1, 2) eq 'п ') {
				$send_to = 'webapp';
				$done = 1;
			} elsif (substr ($m->{message}, 1, 8) eq 'weather ' || substr ($m->{message}, 1, 8) eq 'погодка ') {
				$send_to = 'webapp';
				$done = 1;
			} elsif (substr ($m->{message}, 1, 7) eq 'погода ' || substr ($m->{message}, 1, 8) eq 'погадка ') {
				$send_to = 'webapp';
				$done = 1;
			}
		}
	# Попробуем найти изменение кармы
	} elsif (substr ($m->{message}, -2) eq '++'  ||  substr ($m->{message}, -2) eq '--') {
		my @arr = split /\n/, $m->{message};

		# Предполагается, что фраза - это только одна строка
		if ($#arr < 1) {
			$send_to = 'phrases';
		}
	}

	$log->debug ("[DEBUG] Sending message to channel $send_to " . Dumper ($answer));

	$self->json ($send_to)->notify (
		$send_to => $answer
	);

	return;
};

my $__signal_handler = sub {
	my ($self, $name) = @_;
	$log->info ("[INFO] Caught a signal $name");

	if (defined $main::pidfile && -f $main::pidfile) {
		unlink $main::pidfile;
	}

	exit 0;
};


# main loop, он же event loop
sub RunMisc {
	$log->info ("[INFO] Connecting to $c->{server}, $c->{port}");

	my $redis = Mojo::Redis->new (
		sprintf 'redis://%s:%s/1', $c->{server}, $c->{port}
	);

	$log->info ('[INFO] Registering connection-event callback');

	$redis->on (
		connection => sub {
			my ($r, $connection) = @_;

			$log->info ('[INFO] Triggering callback on new client connection');

			# Залоггируем ошибку, если соединение внезапно порвалось.
			$connection->on (
				error => sub {
					my ($conn, $error) = @_;
					$log->error ("[ERROR] Redis connection error: $error");
					return;
				}
			);

			return;
		}
	);

	my $pubsub = $redis->pubsub;
	my $sub;
	$log->info ('[INFO] Subscribing to redis channels');

	foreach my $channel (@{$c->{channels}}) {
		$log->debug ("[DEBUG] Subscribing to $channel");

		$sub->{$channel} = $pubsub->json ($channel)->listen (
			$channel => sub { $parse_message->(@_); }
		);
	}

	Mojo::IOLoop::Signal->on (
		TERM => $__signal_handler,
		INT  => $__signal_handler
	);

	do { Mojo::IOLoop->start } until Mojo::IOLoop->is_running;
	return;
}

1;

# vim: set ft=perl noet ai ts=4 sw=4 sts=4:
