# Copyright (c) 2010 WorkWare Systems http://www.workware.net.au/
# All rights reserved

# @synopsis:
#
# This module supports checking various 'features' of the C or C++
# compiler/linker environment. Common commands are cc-check-includes,
# cc-check-types, cc-check-functions, cc-with, make-autoconf-h and make-template.
#
# The following environment variables are used if set:
#
## CC       - C compiler
## CXX      - C++ compiler
## CCACHE   - Set to "" to disable automatic use of ccache
## CFLAGS   - Additional C compiler flags
## CXXFLAGS - Additional C++ compiler flags
## LDFLAGS  - Additional compiler flags during linking
## LIBS     - Additional libraries to use (for all tests)
## CROSS    - Tool prefix for cross compilation
#
# The following variables are defined from the corresponding
# environment variables if set.
#
## CPPFLAGS
## LINKFLAGS
## CC_FOR_BUILD
## LD

use system

module-options {}

# Note that the return code is not meaningful
proc cc-check-something {name code} {
	uplevel 1 $code
}

# Checks for the existence of the given function by linking
#
proc cctest_function {function} {
	cctest -link 1 -declare "extern void $function\(void);" -code "$function\();"
}

# Checks for the existence of the given type by compiling
proc cctest_type {type} {
	cctest -code "$type _x;"
}

# Checks for the existence of the given type/structure member.
# e.g. "struct stat.st_mtime"
proc cctest_member {struct_member} {
	lassign [split $struct_member .] struct member
	cctest -code "static $struct _s; return sizeof(_s.$member);"
}

# @cc-check-sizeof type ...
#
# Checks the size of the given types (between 1 and 32, inclusive).
# Defines a variable with the size determined, or "unknown" otherwise.
# e.g. for type 'long long', defines SIZEOF_LONG_LONG.
# Returns the size of the last type.
#
proc cc-check-sizeof {args} {
	foreach type $args {
		msg-checking "Checking for sizeof $type..."
		set size unknown
		# Try the most common sizes first
		foreach i {4 8 1 2 16 32} {
			if {[cctest -code "static int _x\[sizeof($type) == $i ? 1 : -1\] = { 1 };"]} {
				set size $i
				break
			}
		}
		msg-result $size
		set define [feature-define-name $type SIZEOF_]
		define $define $size
	}
	# Return the last result
	get-define $define
}

# Checks for each feature in $list by using the given script.
#
# When the script is evaluated, $each is set to the feature
# being checked, and $extra is set to any additional cctest args.
#
# Returns 1 if all features were found, or 0 otherwise.
proc cc-check-some-feature {list script} {
	set ret 1
	foreach each $list {
		if {![check-feature $each $script]} {
			set ret 0
		}
	}
	return $ret
}

# @cc-check-includes includes ...
#
# Checks that the given include files can be used
proc cc-check-includes {args} {
	cc-check-some-feature $args {
		cctest -includes $each
	}
}

# @cc-check-types type ...
#
# Checks that the types exist.
proc cc-check-types {args} {
	cc-check-some-feature $args {
		cctest_type $each
	}
}

# @cc-check-functions function ...
#
# Checks that the given functions exist (can be linked)
proc cc-check-functions {args} {
	cc-check-some-feature $args {
		cctest_function $each
	}
}

# @cc-check-members type.member ...
#
# Checks that the given type/structure members exist.
# A structure member is of the form "struct stat.st_mtime"
proc cc-check-members {args} {
	cc-check-some-feature $args {
		cctest_member $each
	}
}

# @cc-check-function-in-lib function libs ?otherlibs?
#
# Checks that the given given function can be found on one of the libs.
#
# First checks for no library required, then checks each of the libraries
# in turn.
#
# If the function is found, the feature is defined and lib_$function is defined
# to -l$lib where the function was found, or "" if no library required.
# In addition, -l$lib is added to the LIBS define.
#
# If additional libraries may be needed to linked, they should be specified
# as $extralibs as "-lotherlib1 -lotherlib2".
# These libraries are not automatically added to LIBS.
#
# Returns 1 if found or 0 if not.
# 
proc cc-check-function-in-lib {function libs {otherlibs {}}} {
	msg-checking "Checking for $function..."
	set found 0
	cc-with [list -libs $otherlibs] {
		if {[cctest_function $function]} {
			msg-result "none needed"
			define lib_$function ""
			incr found
		} else {
			foreach lib $libs {
				cc-with [list -libs -l$lib] {
					if {[cctest_function $function]} {
						msg-result $lib
						define lib_$function -l$lib
						define-append LIBS -l$lib
						incr found
						break
					}
				}
			}
		}
	}
	if {$found} {
		define [feature-define-name $function]
	} else {
		msg-result "not found"
	}
	return $found
}

# @cc-check-tools tool ...
#
# Checks for existence of the given compiler tools, taking
# into account any cross compilation prefix.
#
# For example, when checking for "ar", first AR is checked on the command
# line and then in the environment. If not found, "${host}-ar" or
# simply "ar" is assumed depending upon whether cross compiling.
# The path is searched for this executable, and if found AR is defined
# to the executable name.
#
# It is an error if the executable is not found.
#
proc cc-check-tools {args} {
	foreach tool $args {
		set TOOL [string toupper $tool]
		set exe [get-env $TOOL [get-define cross]$tool]
		if {![find-executable $exe]} {
			user-error "Failed to find $exe"
		}
		define $TOOL $exe
	}
}

# @cc-check-progs prog ...
#
# Checks for existence of the given executables on the path.
#
# For example, when checking for "grep", the path is searched for
# the executable, 'grep', and if found GREP is defined as "grep".
#
# It the executable is not found, the variable is defined as false.
# Returns 1 if all programs were found, or 0 otherwise.
#
proc cc-check-progs {args} {
	set failed 0
	foreach prog $args {
		set PROG [string toupper $prog]
		msg-checking "Checking for $prog..."
		if {![find-executable $prog]} {
			msg-result no
			define $PROG false
			incr failed
		} else {
			msg-result ok
			define $PROG $prog
		}
	}
	expr {!$failed}
}

# Adds the given settings to $::autosetup(ccsettings) and
# returns the old settings.
#
proc cc-add-settings {settings} {
	if {[llength $settings] % 2} {
		autosetup-error "settings list is missing a value: $settings"
	}

	set prev [cc-get-settings]
	# workaround a bug in some versions of jimsh by forcing
	# conversion of $prev to a list
	llength $prev

	array set new $prev

	foreach {name value} $settings {
		switch -exact -- $name {
			-cflags - -includes {
				# These are given as lists
				lappend new($name) {*}$value
			}
			-declare {
				lappend new($name) $value
			}
			-libs {
				# Note that new libraries are added before previous libraries
				set new($name) [list {*}$value {*}$new($name)]
			}
			-link - -lang {
				set new($name) $value
			}
			-source - -sourcefile - -code {
				# XXX: These probably are only valid directly from cctest
				set new($name) $value
			}
			default {
				autosetup-error "unknown cctest setting: $name"
			}
		}
	}

	cc-store-settings [array get new]

	return $prev
}

proc cc-store-settings {new} {
	set ::autosetup(ccsettings) $new
}

proc cc-get-settings {} {
	return $::autosetup(ccsettings)
}

# @cc-with settings ?{ script }?
#
# Sets the given 'cctest' settings and then runs the tests in 'script'.
# Note that settings such as -lang replace the current setting, while
# those such as -includes are appended to the existing setting.
#
# If no script is given, the settings become the default for the remainder
# of the auto.def file.
#
## cc-with {-lang c++} {
##   # This will check with the C++ compiler
##   cc-check-types bool
##   cc-with {-includes signal.h} {
##     # This will check with the C++ compiler, signal.h and any existing includes.
##     ...
##   }
##   # back to just the C++ compiler
## }
#
# The -libs setting is special in that newer values are added *before* earlier ones.
#
## cc-with {-libs {-lc -lm}} {
##   cc-with {-libs -ldl} {
##     cctest -libs -lsocket ...
##     # libs will be in this order: -lsocket -ldl -lc -lm
##   }
## }
proc cc-with {settings args} {
	if {[llength $args] == 0} {
		cc-add-settings $settings
	} elseif {[llength $args] > 1} {
		autosetup-error "usage: cc-with settings ?script?"
	} else {
		set save [cc-add-settings $settings]
		set rc [uplevel 1 [lindex $args 0]]
		cc-store-settings $save
		return $rc
	}
}

# @cctest ?settings?
# 
# Low level C compiler checker. Compiles and or links a small C program
# according to the arguments and returns 1 if OK, or 0 if not.
#
# Supported settings are:
#
## -cflags cflags      A list of flags to pass to the compiler
## -includes list      A list of includes, e.g. {stdlib.h stdio.h}
## -declare code       Code to declare before main()
## -link 1             Don't just compile, link too
## -lang c|c++         Use the C (default) or C++ compiler
## -libs liblist       List of libraries to link, e.g. {-ldl -lm}
## -code code          Code to compile in the body of main()
## -source code        Compile a complete program. Ignore -includes, -declare and -code
## -sourcefile file    Shorthand for -source [readfile [get-define srcdir]/$file]
#
# Unless -source or -sourcefile is specified, the C program looks like:
#
## #include <firstinclude>   /* same for remaining includes in the list */
##
## declare-code              /* any code in -declare, verbatim */
##
## int main(void) {
##   code                    /* any code in -code, verbatim */
##   return 0;
## }
#
# Any failures are recorded in 'config.log'
#
proc cctest {args} {
	set src conftest__.c
	set tmp conftest__.o

	# Easiest way to merge in the settings
	cc-with $args {
		array set opts [cc-get-settings]
	}

	if {[info exists opts(-sourcefile)]} {
		set opts(-source) [readfile [get-define srcdir]/$opts(-sourcefile) "#error can't find $opts(-sourcefile)"]
	}
	if {[info exists opts(-source)]} {
		set lines $opts(-source)
	} else {
		foreach i $opts(-includes) {
			if {$opts(-code) eq "" || [have-feature $i]} {
				lappend source "#include <$i>"
			} elseif {![feature-checked $i]} {
				user-notice "Warning: using #include <$i> which has not been checked -- ignoring"
			}
		}
		lappend source {*}$opts(-declare)
		lappend source "int main(void) {"
		lappend source $opts(-code)
		lappend source "return 0;"
		lappend source "}"

		set lines [join $source \n]
	}

	# Build the command line
	set cmdline {}
	lappend cmdline {*}[get-define CCACHE]
	switch -exact -- $opts(-lang) {
		c++ {
			lappend cmdline {*}[get-define CXX] {*}[get-define CXXFLAGS]
		}
		c {
			lappend cmdline {*}[get-define CC] {*}[get-define CFLAGS]
		}
		default {
			autosetup-error "cctest called with unknown language: $opts(-lang)"
		}
	}

	if {!$opts(-link)} {
		lappend cmdline -c
	}
	lappend cmdline {*}$opts(-cflags)

	switch -glob -- [get-define host] {
		*-*-darwin* {
			# Don't generate .dSYM directories
			lappend cmdline -gstabs
		}
	}
	lappend cmdline $src -o $tmp {*}$opts(-libs)

	# At this point we have the complete command line and the
	# complete source to be compiled. Get the result from cache if
	# we can
	if {[info exists ::cc_cache($cmdline,$lines)]} {
		set ok $::cc_cache($cmdline,$lines)
		if {$::autosetup(debug)} {
			configlog "From cache (ok=$ok): [join $cmdline]"
			configlog "============"
			configlog $lines
			configlog "============"
		}
		return $ok
	}

	writefile $src $lines\n

	set ok 1
	if {[catch {exec {*}$cmdline 2>@1} result errinfo]} {
		configlog "Failed: [join $cmdline]"
		configlog $result
		configlog "============"
		configlog "The failed code was:"
		configlog $lines
		configlog "============"
		set ok 0
	} elseif {$::autosetup(debug)} {
		configlog "Compiled OK: [join $cmdline]"
		configlog "============"
		configlog $lines
		configlog "============"
	}
	file delete $src
	file delete $tmp

	# cache it
	set ::cc_cache($cmdline,$lines) $ok

	return $ok
}

# @make-autoconf-h outfile ?patternlist?
#
# Examines all defined variables which match the given patterns
# and writes an include file, $file, which defines each of these.
# - defines which have the value "0" are ignored.
# - defines which have integer values are defined as the integer value.
# - any other value is defined as a string, e.g. "value"
# 
# If the file would be unchanged, it is not written.
proc make-autoconf-h {file {patterns {HAVE_* SIZEOF_*}}} {
	set guard _[string toupper [regsub -all {[^a-zA-Z0-9]} [file tail $file] _]]
	file mkdir [file dirname $file]
	set lines {}
	lappend lines "#ifndef $guard"
	lappend lines "#define $guard"
	foreach pattern $patterns {
		foreach n [lsort [array names ::define $pattern]] {
			if {$::define($n) eq "0"} {
				lappend lines "/* #undef $n */"
			} elseif {[string is integer -strict $::define($n)]} {
				lappend lines "#define $n $::define($n)"
			} else {
				lappend lines "#define $n \"$::define($n)\""
			}
		}
	}
	lappend lines "#endif"
	set buf [join $lines \n]
	write-if-changed $file $buf {
		msg-result "Created $file"
	}
}

# Initialise some values from the environment or commandline or default settings
foreach i {LDFLAGS LIBS CPPFLAGS LINKFLAGS {CFLAGS "-g -O2"} {CC_FOR_BUILD cc}} {
	lassign $i var default
	define $var [get-env $var $default]
}

if {[env-is-set CC]} {
	# Set by the user, so don't try anything else
	set try [get-env CC ""]
} else {
	# Try some reasonable options
	set try [list [get-define cross]cc [get-define cross]gcc]
}
define CC [find-an-executable {*}$try]
if {[get-define CC] eq ""} {
	user-error "Could not find a C compiler. Tried: [join $try ", "]"
}

define CPP [get-env CPP "[get-define CC] -E"]

# XXX: Could avoid looking for a C++ compiler until requested
# Note that if CXX isn't found, we just set it to "false". It might not be needed.
if {[env-is-set CXX]} {
	define CXX [find-an-executable -required [get-env CXX ""]]
} else {
	define CXX [find-an-executable [get-define cross]c++ [get-define cross]g++ false]
}

# CXXFLAGS default to CFLAGS if not specified
define CXXFLAGS [get-env CXXFLAGS [get-define CFLAGS]]

cc-check-tools ld

define CCACHE [find-an-executable [get-env CCACHE ccache]]

# Initial cctest settings
cc-store-settings {-cflags {} -includes {} -declare {} -link 0 -lang c -libs {} -code {}}

msg-result "C compiler...[get-define CCACHE] [get-define CC] [get-define CFLAGS]"
if {[get-define CXX] ne "false"} {
	msg-result "C++ compiler...[get-define CCACHE] [get-define CXX] [get-define CXXFLAGS]"
}

if {![cc-check-includes stdlib.h]} {
	user-error "Compiler does not work. See config.log"
}
