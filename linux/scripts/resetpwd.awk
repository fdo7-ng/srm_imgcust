#!/bin/awk -f

# Awk script to force root accounts to change the password on next
# login and set the root password. We use different ways to achieve this.
# 1. If chage binary is installed, we use chage -d 0 command line to expire
#    the password for all root accounts.
# 2. If we are running on solaris, we use passwd -f command line to expire
#    the password for all root accounts
# 3. If we have chpasswd binary installed, we use it to set the root password
# 4. If we have passwd binary supporting --stdin command line, we use it to
#    set the root password.
# 5. If there are not standard commands to set password expiry and/or root
#    password, we directly edit the /etc/shadow file

BEGIN {
   #Initialize variables
   FS = ":";
   OFS = ":";
   CHAGE = "/usr/bin/chage";
   CHPASSWD = "/usr/sbin/chpasswd";
   OPENSSL = "/usr/bin/openssl";
   RPM = "/bin/rpm";
   BASE64 = "/usr/bin/base64";
   tweak_shadow = 0;
   use_chage = 0;
   use_passwd = 0;
   use_chpasswd = 0;
   use_passwd_stdin = 0;
   use_openssl = 0;
   # this is needed because calling exit(1); in BEGIN doesn't prevent END block
   # from executing and returning it's own exit code
   _assert_exit = 0;

   print("Starting resetpwd.awk...");

   print("Checking "BASE64"...");
   if (system("test -x "BASE64) != 0) {
      print(BASE64" is not found. Halting!");
      _assert_exit = 1;
      exit(1);
   }
   # this should work fine with empty string too which is Cg==
   print("Decoding password: "(length(password) > 0));
   if(length(password) > 0) {
      decode_cmd = "echo "password" | "BASE64" -di";
      decode_cmd | getline password;
      print("Decoding password completed");
   }

   if (expirepassword == 1) {
      print("Expiring password...");
      # Check if chage binary exist and has execute bit set and set
      # use_chage accordingly.
      if (system("test -x "CHAGE) == 0) {
         use_chage = 1;
      } else {
         #Check if running on Solaris and if so set use_passwd to 1
         #indicating that we can use passwd command line.
         uname_cmd = "uname -s";
         uname_cmd | getline ostype;
         if (ostype == "SunOS") {
            use_passwd = 1;
         }
      }
   } else {
     print("No need to expire password");
   }

   if (setpassword == 1) {
      print("Setting password...");
      # Check if chpasswd binary exist and has execute bit set and set
      # use_chpasswd accordingly.
      if (system("test -x "CHPASSWD) == 0) {
         print("chpasswd is found");
         use_chpasswd = 1;
         cmd = CHPASSWD" --help 2>&1 | grep -e --md5 | wc -l";
         cmd | getline use_chpasswd_md5;
         if (use_chpasswd_md5) {
            print("'chpasswd --md5' will be used");
            CHPASSWD = CHPASSWD" --md5";
         } else {
            print("WARNING: chpasswd will be used without MD5 as it doesn't support it!");
         }
         # All RedHats should have RPM as its their native package manager
         if (system("test -x "RPM) == 0) {
            print(RPM" is found");
            # RHEL5's chpasswd has a buffer overflow bug, which prevents use of --md5
            cmd = "rpm -q shadow-utils | grep -e 4.0.17-12 | wc -l";
            cmd | getline is_rhel5_chpasswd;
            if (is_rhel5_chpasswd) {
               print("RHEL5 buffer overflow bug detected - not using chpasswd");
               use_chpasswd = 0;
            } else {
               print("RHEL5 buffer overflow bug is not detected");
            }
            # CentOS 4.8's chpasswd has bug which produces error when "--md5" option is used
            # This is true for the latest version of shadow-utils available there
            cmd = "rpm -q shadow-utils | grep -e 4.0.3-66 | wc -l";
            cmd | getline is_centos48_chpasswd;
            if (is_centos48_chpasswd) {
               print("CentOs 4.8 bug detected - not using chpasswd");
               use_chpasswd = 0;
            } else {
               print("CentOs 4.8 bug is not detected");
            }
         } else {
           print(RPM" is not found");
         }
      } else {
         # Check if passwd supports --stdin command line to set the password
         # and set use_passwd_stdin accordingly.
         cmd = "passwd --help 2>&1 | grep -e --stdin | wc -l";
         cmd | getline use_passwd_stdin;
      }
      if (system("test -x "OPENSSL) == 0) {
         # If OpenSSL is available, we'll use it to generate passwords instead
         # of perl.
         use_openssl = 1;
      }
   } else {
     print("No need to set password");
   }

   # If we cannot use passwd or chage command line to expire the password,
   # we diectly tweak /etc/shadow file.
   if ((expirepassword == 1) && (use_chage == 0) && (use_passwd == 0)) {
      tweak_shadow = 1;
   }

   # If we cannot use passwd or chpasswd command line to change the
   # root password, we diectly tweak /etc/shadow file.
   if ((setpassword == 1) && (use_passwd_stdin == 0) && (use_chpasswd == 0)) {
      tweak_shadow = 1;
   }

   # If we are setting password and we are tweaking shadow, we need OpenSSL or
   # perl to encrypt the password
   if ((tweak_shadow == 1) && (setpassword==1)) {
      if (use_openssl == 1) {
         pwdcmd = "echo '"password"' | "OPENSSL" passwd -1 -stdin";
         pwdcmd | getline encryptedpassword;
      } else {
         # Fall back to perl. Uses crypt(), which only looks at the first 8 characters
         # of the password.
         perlpath = ENVIRON["PERL"];
         if (perlpath == "") {
            print("Perl not found");
            exit(1);
         }

         # Encrypt the password using perl script.
         perlcmd = perlpath" -e 'my $salts=\"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789./\"; my $s1 = rand(64); my $s2 = rand(64); my $salt = substr($salts,$s1,1) . substr($salts,$s2,1); print crypt($ARGV[0], $salt)' " password;
         perlcmd | getline encryptedpassword;
      }
   }

   # Find all users with uid 0 and store them in an array
   while (getline < "/etc/passwd" > 0) {
      if ($3 == 0) {
         allrootusers[$1]=$1;
      }
   }

   if (tweak_shadow == 1) {
      # This flag gets set to 1 when all lines in the input file are
      # successfully processed.
      shadow_processed = 0;

      # Count number of lines in input file. We use this to detect if all
      # lines are processed successfully. We overwrite /etc/shadow in the
      # END section only if all lines in the input file are processed without
      # any errors.
      numlines = 0;
      cmd = "cat "ARGV[1]" | wc -l";
      cmd | getline numlines;

      SHADOW = "/etc/shadow";

      # Ensure that shadow file exists
      if (system("test -f "SHADOW) != 0)  {
         print("Shadow file doesn't exist");
         exit(1);
      }

      # Create name for the backup shadow file based on date & time
      "date +%F-%H:%M:%S" | getline datetime;
      SHADOW_BKP = SHADOW".backup."datetime;

      # Temporary /etc/shadow file that we will use for tweaking
      SHADOW_TMP = SHADOW".tmp";

      # Backup /etc/shadow file
      shadow_backup_cmd = "cp -f "SHADOW" "SHADOW_BKP;
      if (system(shadow_backup_cmd) != 0) {
         print("Unable to backup shadow file");
         exit(1);
      }
   }
}

#The block below is executed for each line in the input file
{
   is_root = 0;
   # Set the is_uid0 flag depending upon if user exists in allrootusers
   if ($1 in allrootusers) {
      is_uid0 = 1;
      if ($1 == "root") {
         is_root = 1;
      }
   } else {
      is_uid0 = 0;
   }

   if (tweak_shadow == 1) {
      if (is_uid0 == 1) {
         # Tweak appropriate fields in the /etc/shadow depending upon
         # whether we are expiring password and/or setting the root
         # password.
         printf("%s:%s:%s:",
                $1,
                (setpassword == 1 && is_root == 1) ? encryptedpassword : $2,
                (expirepassword == 1) ? 0 : $3) > SHADOW_TMP
         for(i=4; i<NF; i++) {
            printf($i) > SHADOW_TMP
            if (i!=NF) printf(":") > SHADOW_TMP;
         }
         printf("\n") > SHADOW_TMP
      } else {
         print($0) > SHADOW_TMP
      }

      # When we are done with processing all the lines, set shadow_processed
      # flag. We overwrite /etc/shadow in END section only if this flag is set.
      if (NR == numlines) {
         shadow_processed = 1;
      }

      # Go to process next record in the input file
      next;
   }

   # Set the root password using standard commands.
   if ((setpassword == 1) && (is_root == 1)) {
      # Use appropriate way to the set the password for root user
      if (use_chpasswd == 1) {
         # Spawn chpasswd command to set the password
         cmd = "echo 'root:"password"' | "CHPASSWD;
         if (system(cmd) != 0) {
            print("chpasswd command failed");
         }
      }
      else if (use_passwd_stdin == 1) {
         # Spawn passwd --stdin command to force user to change the password
         # on next logon
         cmd = "echo '"password"' | passwd --stdin root";
         if (system(cmd) != 0) {
            print("passwd --stdin command failed");
         }
      }
   }

   # Expire the password using standard commands
   if ((expirepassword == 1) && (is_uid0 == 1)) {
      # Use appropriate way to force root users to change password
      # on next login.
      if (use_passwd == 1) {
         # Spawn passwd command to force user to change the password
         # on next logon
         if (system("passwd -f "$1) != 0) {
            print("passwd -f "$1" command failed");
         }
      }
      else if (use_chage == 1) {
         # Spawn chage command to force user to change the password
         # on next logon
         if (system("chage -d 0 "$1) != 0) {
            print("chage -d 0 "$1" command failed");
         }
      }
   }
}

END {
   if (_assert_exit) {
      print("Caught assert: "_assert_exit);
      exit(1);
   }
   if ((tweak_shadow == 1) && (shadow_processed == 1)) {
      if (system("mv -f "SHADOW_TMP" "SHADOW) != 0) {
         print("Unable to move modified shadow file to "SHADOW);
         exit(1);
      }
      if (system("chmod 400 "SHADOW) != 0) {
         print("Unable to set readonly attributes on file "SHADOW);
         exit(1);
      }
   }
   print("resetpwd.awk completed successfully");
   exit(0);
}

