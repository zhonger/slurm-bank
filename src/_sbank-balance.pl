#!/usr/bin/perl -w

# Emulate Gold's 'mybalance' script for SLURM
# 
# Assumes Enforced Limits, with GrpCPUMins set on Accounts (not users)
# 
# Specifically, the following must be set in slurm.conf:
#     AccountingStorageEnforce=limits or AccountingStorageEnforce=safe
# 
# Note there is no longer a requirement to disable half-life decay, as in
# previous versions.
# 
# Requires 'sacctmgr' and 'sreport', and requires a SlurmDBD.
# 
# Note this is a re-write of the previous version, which used 'sshare' to
# obtain usage information. The 'sshare' command reads from local usage
# files, whereas as 'sreport' reads from the SlurmDBD. Specifically, 'sshare'
# values will decay if half-life decay is enabled, while 'sreport' values
# will not decay, and so give an actual usage.
# 

# TODO:
# - re-write using SLURM-Perl API


use strict;
use Getopt::Std;
use POSIX qw(strftime);


my %acc_limits = ();
my %acc_usage = ();
my %user_usage = ();
my %user_usage_per_acc = ();
my @my_accs = ();
my $thisuser = (getpwuid($<))[0];	# who is running the script
my $showallusers = 1;
my $showallaccs = 0;
my $clustername = "";
my $accountname = "";
my ($account, $user, $rawusage, $prev_acc);
my $sreport_start = "";
my $sreport_end   = "";
my $SREPORT_START_OFFSET = 94608000;	# 3 * 365 days, in seconds
my $SREPORT_END_OFFSET   = 172800;	# 2 days to avoid DST issues, in seconds


#####################################################################
# subroutines
#####################################################################
sub usage() {
	print "Usage:\n";
	print "$0 [-h] [-c clustername] [-a accountname] [-u] [-A] [-U username] [-s yyyy-mm-dd]\n";
	print "\t-h:\tshow this help message\n";
	print "\t-c:\tdisplay per cluster 'clustername' (defaults to the local cluster)\n";
	print "\t-a:\tdisplay unformatted balance of account 'accountname' (defaults to all accounts of the current user)\n";
	print "\t-u:\tdisplay only the current user's balances (defaults to all users in all accounts of the current user)\n";
	print "\t-A:\tdisplay all accounts (defaults to all accounts of the current user; implies '-u')\n";
	print "\t-U:\tdisplay information for the given username, instead of the current user\n";
	die   "\t-s:\treport usage starting from yyyy-mm-dd, instead of " . ($SREPORT_START_OFFSET / 365 / 86400) . " years ago\n";
}

# format minutes as hours, with thousands comma separator
sub fmt_mins_as_hrs( $ ) {
	my $n = shift;

	return thous(sprintf("%.0f", $n/60));
}

# add commas
sub thous( $ ) {
	my $n = shift;
	1 while ($n =~ s/^(-?\d+)(\d{3})/$1,$2/);
	return $n;
}

# print headers for the output
sub print_headers() {
	printf "%-10s %9s | %14s %9s | %13s %9s (CPU hrs)\n",
		"User", "Usage", "Account", "Usage", "Account Limit", "Available";
	printf "%10s %9s + %14s %9s + %13s %9s\n",
		"-"x10, "-"x9, "-"x14, "-"x9, "-"x13, "-"x9;
}

# print the formatted values
sub print_values( $$$$$ ) {
	my $thisuser = shift;
	my $user_usage = shift;
	my $acc = shift;
	my $acc_usage = shift;
	my $acc_limit = shift;

	printf "%-10s %9s | %14s %9s | %13s %9s\n",
		$thisuser, fmt_mins_as_hrs($user_usage),
		$acc, fmt_mins_as_hrs($acc_usage),
		fmt_mins_as_hrs($acc_limit),
		fmt_mins_as_hrs($acc_limit - $acc_usage);
}

# print the formatted values
sub print_results( $$$ ) {
	my $multiple_users = shift;
	my $multiple_accs  = shift;
	my $include_root   = shift;

	my @account_list = sort keys %user_usage_per_acc;
	my $first_iter   = 1;

	if ($include_root) {
		# instead of a purely sorted list, show the 'ROOT' account first (assuming
		# that the account is actually called 'ROOT')
		my $root_acc = 'ROOT';

		# linear search (even though the list is sorted and we could do a binary)
		my $index = 0;
		$index++ until ($index > $#account_list || $account_list[$index] eq $root_acc);

		# remove that index from the array
		splice(@account_list, $index, 1);

		# and push 'ROOT' back as the first element
		unshift(@account_list, $root_acc);
	}

        print_headers();
        #printf "\n";

	# now print the values, including those users with no usage
	foreach my $account (@account_list) {

		if (!$first_iter && $multiple_accs) {
			# separate each account
			print "\n";
		}
		$first_iter = 0;

		if (!$multiple_users) {
			# only reporting for a single user

			# stop warnings if this account doesn't have a limit
			if (! exists($acc_limits{$account})) {
				$acc_limits{$account} = 0;
			}

			# stop warnings if this account doesn't have any usage
			if (! exists($acc_usage{$account})) {
				$acc_usage{$account} = 0;
			}

			#print_values($thisuser, $user_usage{$account}, $account, $acc_usage{$account}, $acc_limits{$account});
			print_values($thisuser, $user_usage_per_acc{$account}{$thisuser}, $account, $acc_usage{$account}, $acc_limits{$account});

		} else {
			# else loop over the users

			foreach my $user (sort keys %{ $user_usage_per_acc{$account} } ) {
				# then each subsequent line is an individual user
				# (already in alphabetical order)

				$rawusage = $user_usage_per_acc{$account}{$user};

				# highlight current user
				if ($multiple_users && $user eq $thisuser) {
					$user = "$user *";
				}

				# stop warnings if this account doesn't have a limit
				if (! exists($acc_limits{$account})) {
					$acc_limits{$account} = 0;
				}

				# stop warnings if this account doesn't have any usage
				if (! exists($acc_usage{$account})) {
					$acc_usage{$account} = 0;
				}

				print_values($user, sprintf("%.0f", $rawusage), $account, $acc_usage{$account}, $acc_limits{$account});
			}
		}
	}
}

# query sacctmgr to find the list of users and accounts
# populates the global %user_usage_per_acc HashOfHash
# if $populate_my_accs is not empty, also populate global @my_accs list
sub query_users_and_accounts( $$$ ) {
	my $account_param    = shift;
	my $user_param       = shift;
	my $populate_my_accs = shift;

	my $cluster_str = ($clustername ne "") ? "clusters=$clustername " : "";
	my $query_str = "sacctmgr list accounts withassoc -np $cluster_str format=Account,User ";

	if ($account_param) {
		$query_str .= "accounts=$account_param ";
	} elsif ($user_param) {
		$query_str .= "users=$user_param ";
	}

	# open the pipe and run the query
	open (SACCTMGR, "$query_str |") or die "$0: Unable to run sacctmgr: $!\n";

	while (<SACCTMGR>) {
		# only show outputs for accounts we're part of
		if (/^\s*([^|]+)\|([^|]+)\|/) {
			my $account   = "\U$1";
			my $user      = "$2";

			# put in a zero usage explicitly if the user hasn't run at all
			$user_usage_per_acc{$account}{$user} = 0;

		}
	}

	close(SACCTMGR);

	if ($populate_my_accs) {
		# but only look at my accounts, not all accounts
		foreach my $account (sort keys %user_usage_per_acc) {
			if (exists ($user_usage_per_acc{$account}{$thisuser}) ) {
				push (@my_accs, $account);
			} else {
				# remove the account
				delete $user_usage_per_acc{$account};
			}
		}
	}
}

# query sreport/sshare to find the actual usage, for users and/or accounts
# populates the global %user_usage_per_acc HashOfHash
sub query_sreport_user_and_account_usage( $$$ ) {
	my $account_param    = shift;
	my $balance_only     = shift;
	my $thisuser_only    = shift;

	my $cluster_str = ($clustername ne "") ? "clusters=$clustername " : "";
	my $query_str = "sreport -t minutes -np cluster AccountUtilizationByUser start=$sreport_start end=$sreport_end $cluster_str account=$account_param ";

	# open the pipe and run the query
	open (SREPORT, "$query_str |") or die "$0: Unable to run sreport: $!\n";

	while (<SREPORT>) {
		# only show outputs for accounts we're part of
		if (/^\s*[^|]+\|([^|]*)\|([^|]*)\|[^|]*\|([^|]*)/) {
			$account      = "\U$1";
			$user         = $2;
			$rawusage     = $3;

			if (exists( $acc_limits{$account} ) && $user eq "") {
				# the first line is the overall account usage
				$acc_usage{$account} = $rawusage;

				# if we only want the unformatted balance, then we're done
				if ($balance_only) {
					last;
				}

			} elsif ($thisuser_only && $user eq $thisuser && exists( $acc_limits{$account} )) {
                                # only reporting on the given user, not on all users in the account
                                $user_usage_per_acc{$account}{$thisuser} = $rawusage;

			} elsif (exists( $acc_limits{$account} )) {
				# otherwise report on all users in the account
				$user_usage_per_acc{$account}{$user} = $rawusage;

			}
		}
	}

	close(SREPORT);
}


#####################################################################
# get options
#####################################################################
my %opts;
getopts('huU:c:a:As:', \%opts) || usage();

if (defined($opts{h})) {
	usage();
}

if (defined($opts{u})) {
	$showallusers = 0;
}

if (defined($opts{U})) {
	$thisuser = $opts{U};
}

if (defined($opts{c})) {
	$clustername = $opts{c};
}

if (defined($opts{a})) {
	$accountname = $opts{a};
}

if (defined($opts{A})) {
	$showallaccs = 1;
}

if (defined($opts{s})) {
	unless ($opts{s} =~ /^\d{4}-\d{2}-\d{2}$/) { usage(); }

	$sreport_start = $opts{s};
	$sreport_end   = strftime "%Y-%m-%d", (localtime(time() + $SREPORT_END_OFFSET));
} else {
	$sreport_start = strftime "%Y-%m-%d", (localtime(time() - $SREPORT_START_OFFSET));
	$sreport_end   = strftime "%Y-%m-%d", (localtime(time() + $SREPORT_END_OFFSET));
}


#####################################################################
# start
# get the local clustername, or use the given clustername
#####################################################################

if ($clustername eq "") {
	open (SCONTROL, 'scontrol show config |')
		or die "$0: Unable to run scontrol: $!\n";

	while (<SCONTROL>) {
		if (/^ClusterName\s*=\s*(\S+)/) {
			$clustername = $1;
		}
	}

	close(SCONTROL);

	if ($clustername eq "") {
		die "$0: Unable to determine local cluster name via scontrol. Exiting..\n";
	}
}


#####################################################################
# run sacctmgr to find all Account limits from the list of 
# Assocations
# note that gives us the current active Accounts, which is useful
# because sreport will show usage from deleted accounts
#####################################################################

open (SACCTMGR, "sacctmgr list association cluster=$clustername format='Account,GrpCPUMins'" .
		" -p -n |")
	or die "$0: Unable to run sacctmgr: $!\n";

# GrpCPUMins are not in 'sreport'
while (<SACCTMGR>) {
	# format is "acct_string|nnnn|" where nnnn is the number of GrpCPUMins allocated
	if (/^([^|]+)\|([^|]*)/) {
		if ($2 ne "") {
			$acc_limits{"\U$1"} = sprintf("%.0f", $2);
		}
	}
}

close(SACCTMGR);


#####################################################################
# quick sanity check - did we find any GrpCPUMins ?
#####################################################################

if ((scalar keys %acc_limits) == 0) {
	die "$0: Unable to find any GrpCPUMins set on Accounts in cluster '$clustername' via sacctmgr. Exiting..\n";
}


#########################################################################################
# main code: there are a few different combinations:
# - Scenario #1 showallusers in a named account
# - Scenario #2 showallusers in every account, not just mine
# - Scenario #3 showallusers in all of my accounts
# - Scenario #4 show unformatted balance as a single figure, for the named account
# - Scenario #5 show only my usage, in all of my accounts
#########################################################################################


if ($showallusers && $accountname ne "") {
	#####################################################################
	# - Scenario #1 showallusers in a named account
	# only look to a specified account, rather than all
	# show all users in the given account
	#####################################################################

	my $cluster_str = ($clustername ne "") ? "clusters=$clustername " : "";

	# first obtain the full list of users for this account; sreport won't report
	# on them if they have no usage
	query_users_and_accounts($accountname, "", "");

	# get the usage values (for all users in the accounts), for just the named account
	query_sreport_user_and_account_usage($accountname, "", "");

	# display formatted output
	print_results(1, 0, 0);

} elsif ($showallusers && $showallaccs) {
	#####################################################################
	# - Scenario #2 showallusers in every account, not just mine
	# we need to show all users in ALL Accounts
	#####################################################################

	my $cluster_str = ($clustername ne "") ? "clusters=$clustername " : "";

	# first obtain the full list of users for all accounts; sreport won't report
	# on them if they have no usage
	query_users_and_accounts("", "", "");

	# get the usage values (for all users in the accounts), for all accounts (all the ones found by sacctmgr above)
	query_sreport_user_and_account_usage(join(',', sort(keys (%acc_limits))), "", "");

	# display formatted output
	print_results(1, 1, 1);

} elsif ($showallusers) {
	#####################################################################
	# - Scenario #3 showallusers in all of my accounts
	# if we need to show all users in all our Accounts, then we have to
	# run sacctmgr first, then sreport - first to find all Accounts that I'm a part of,
	# and secondly to dump all users in those accounts
	#####################################################################

	my $cluster_str = ($clustername ne "") ? "clusters=$clustername " : "";

	###############################################################################
	# sacctmgr #1 -- obtain the usage for this user, and also the list of all of their accounts
	###############################################################################

	# first obtain the full list of users for all accounts; sreport won't report
	# on them if they have no usage
	query_users_and_accounts("", "", 1);

	# get the usage values (for all users in the accounts), for all the accounts of the given user
	query_sreport_user_and_account_usage(join(',', sort(@my_accs)), "", "");

	# display formatted output
	print_results(1, 1, 0);

} elsif ($accountname ne "") {
	#####################################################################
	# - Scenario #4 show unformatted balance as a single figure, for the named account
	# show only the balance for $accountname, unformatted
	#####################################################################

	#my $cluster_str = ($clustername ne "") ? "-M $clustername " : "";
	my $cluster_str = ($clustername ne "") ? "clusters=$clustername " : "";

	$rawusage = "";	# init to a value to stop perl warnings

	# get the usage value, for all single given account
	query_sreport_user_and_account_usage($accountname, 1, "");

	if ($acc_usage{$accountname} eq "") {
		die "$0: invalid account string '$accountname'\n";
	}

	# this is minutes - we need to convert to hours
	printf "%.0f\n", (($acc_limits{$accountname} - $acc_usage{$accountname})/60);

} else {
	#####################################################################
	# - Scenario #5 show only my usage, in all of my accounts
	# only show my usage in the Accounts
	# run sacctmgr first, then sreport - first to find all Accounts that I'm a part of,
	# and secondly to dump all users in those accounts
	#####################################################################

	my $cluster_str = ($clustername ne "") ? "clusters=$clustername " : "";

	###############################################################################
	# sacctmgr #1 -- obtain the usage for this user, and also the list of all of their accounts
	###############################################################################

	query_users_and_accounts("", $thisuser, 1);

	# get the usage values (for just the given user), for all the accounts of the given user
	query_sreport_user_and_account_usage(join(',', sort(@my_accs)), "", 1);

	# display formatted output
	print_results(0, 0, 0);

}

