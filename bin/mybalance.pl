#!/usr/bin/perl -w

# Emulate Gold's 'mybalance' script for SLURM
# 
# Assumes Enforced Limits, with GrpCPUMins set on Accounts
# 
# Requires 'sacctmgr' and 'sshare'
# 

# TODO:
# - fix clustername (chuck currently hardcoded) - maybe find it from scontrol ?
# - have option to run for multiple/all clusters
# - re-write using SLURM-Perl API


use strict;
use Getopt::Std;


my %acc_limits = ();
my %acc_usage = ();
my %user_usage = ();
my $thisuser = (getpwuid($<))[0];	# who's running the script
my $showallusers = 0;
my ($account, $user, $rawusage, $prev_acc);


#####################################################################
# subroutines
#####################################################################
sub usage() {
        print "Usage:\n";
        print "$0 [-h] [-a]\n";
	print "\t-h:\tshow this help message\n";
	die   "\t-a:\tshow all users in the account\n";
}

# add commas
sub thous( $ ) {
	my $n = shift;
	1 while ($n =~ s/^(-?\d+)(\d{3})/$1,$2/);
	return $n;
}


#####################################################################
# get options
#####################################################################
my %opts;
getopts('ha', \%opts) || usage();

if (defined($opts{h})) {
        usage();
}

if (defined($opts{a})) {
        $showallusers = 1;
}


#####################################################################
# start
# run sacctmgr to find all Account limits from the list of 
# Assocations
#####################################################################

# FIXME: cluster name(s) !!
open (SACCTMGR, 'sacctmgr list association cluster=chuck format="Cluster,Account,User,GrpCPUMins"' .
		' -p -n | awk -F"|" \'{if ($4 != "") print $2 " " $4}\' |')
	or die "$0: Unable to run sacctmgr: $!\n";

# GrpCPUMins are not in 'sshare'
while (<SACCTMGR>) {
	# format is "acct_string nnnn" where nnnn is the number of GrpCPUMins allocated
	if (/^(\S+)\s+(\d+)$/) {
		$acc_limits{"\U$1"} = sprintf("%.0f", $2);
	}
}

close(SACCTMGR);


#####################################################################
# if we need to show all users in our Accounts, then we have to
# run sshare twice - once to find all Accounts that I'm a part of,
# and secondly to dump all users in those accounts
#####################################################################

if ($showallusers) {
	# complex version:
	# show all users in only my Accounts

	my @my_accs = ();

	# firstly grab the list of accounts that I'm a part of
	open (SSHARE, "sshare -hp |") or die "$0: Unable to run sacctmgr: $!\n";

	while (<SSHARE>) {
		# only show outputs for accounts we're part of
		if (/^\s*([^|]+)\|([^|]*)\|[^|]*\|[^|]*\|([^|]*)/) {
			$account      = "\U$1";
			$user         = $2;
			$rawusage     = $3;

			if ($user ne "") {
				# build up list of my accounts
				push @my_accs, $account;
			} elsif (exists($acc_limits{$account})) {
				# and store the account limits while we're here
				$acc_usage{$account} = sprintf("%.0f", $rawusage/60);
			}
		}
	}

	close(SSHARE);


	# display formatted output
	printf "%-10s %11s | %16s %11s | %13s %11s (CPU hrs)\n",
		"User", "Usage", "Account", "Usage", "Account Limit", "Available";
	printf "%10s %11s + %16s %11s + %13s %11s\n",
		"-"x10, "-"x11, "-"x16, "-"x11, "-"x13, "-"x11;


	# now, display all users from just those accounts
	open (SSHARE2, "sshare -aA " . (join ",",@my_accs) . " -hp 2>/dev/null |") or die "$0: Unable to run sacctmgr: $!\n";

	$prev_acc = "";

	while (<SSHARE2>) {
		if (/^\s*([^|]+)\|([^|]*)\|[^|]*\|[^|]*\|([^|]*)/) {
			if ($prev_acc ne "" && $account ne $prev_acc) {
				print "\n";
			}
			if ($account ne "") {
				$prev_acc = $account;
			}

			$account      = "\U$1";
			$user         = $2;
			$rawusage     = $3;

			next if($user eq "");

			if ($user eq $thisuser) {
				$user = "$user *";
			}

			printf "%-10s %11s | %16s %11s | %13s %11s\n",
				$user, thous(sprintf("%.0f", $rawusage/60)),
				$account, thous($acc_usage{$account}),
				thous($acc_limits{$account}),
				thous($acc_limits{$account} - $acc_usage{$account});
		}
	}

	close(SSHARE2);

} else {
	# simple version:
	# only show my usage in the Accounts

	open (SSHARE, "sshare -hp |") or die "$0: Unable to run sacctmgr: $!\n";

	while (<SSHARE>) {
		# only show outputs for accounts we're part of
		if (/^\s*([^|]+)\|([^|]*)\|[^|]*\|[^|]*\|([^|]*)/) {
			$account      = "\U$1";
			$user         = $2;
			$rawusage     = $3;

			if (exists($acc_limits{$account}) && $user eq $thisuser) {
				$user_usage{$account} = sprintf("%.0f", $rawusage/60);
			} elsif (exists($acc_limits{$account})) {
				$acc_usage{$account} = sprintf("%.0f", $rawusage/60);
			}
		}
	}

	close(SSHARE);


	# display formatted output
	printf "%-10s %11s | %16s %11s | %13s %11s (CPU mins)\n",
		"User", "Usage", "Account", "Usage", "Account Limit", "Available";
	printf "%10s %11s + %16s %11s + %13s %11s\n",
		"-"x10, "-"x11, "-"x16, "-"x11, "-"x13, "-"x11;

	foreach my $acc (sort keys %user_usage) {
		printf "%-10s %11s | %16s %11s | %13s %11s\n",
			$thisuser, thous($user_usage{$acc}),
			$acc, thous($acc_usage{$acc}),
			thous($acc_limits{$acc}),
			thous($acc_limits{$acc} - $acc_usage{$acc});
	}
}

