#  -*-  mode: sh -*-
# resty - A tiny command line REST interface for bash and zsh.
#
# Fork me on github:
#   http://github.com/micha/resty
#
# Author:
#   Micha Niskin <micha@thinkminimo.com>
#   Copyright 2009-2017, MIT licence.
#
# Maintener:
#   Adriean Khisbe <adriean.khisbe@live.fr>
#


export _RESTY_HOST=""
export _RESTY_OPTS=""
export _RESTY_DOMAIN=""
export _RESTY_PATH=""
export _RESTY_NO_HISTORY=""
export _RESTY_H2T="$( (exec 2>&-; (which lynx >/dev/null && echo "lynx -stdin -dump") \
			  || which html2text || which cat) |tail -n 1)"
export _RESTY_EDITOR=$( (exec 2>&-; which "$EDITOR" || which vim || echo "vi") |tail -n 1)    # editor default

export _RESTY_DIR

export _RESTY_JSON_PRINTER="perl -0007 -MJSON -ne'print to_json(from_json($_, {allow_nonref=>1}),{pretty=>1}).\"\n\"'"

_RESTY_DIR="$HOME/.resty"
mkdir -p "$_RESTY_DIR/cookies"

function resty {
	local url; url="$1"; [ -n "$1" ] && shift
	if [ -n "$url" ] && [[ "HEAD OPTIONS GET PATCH POST PUT TRACE DELETE" =~ $url ]] ; then
		resty-call $url "$@"
		return
	fi

	if [ -n "$(which jq)" ]; then
		_RESTY_JSON_PRINTER="jq"
	elif [ -n "$(python3)" ]; then
		_RESTY_JSON_PRINTER="python3 -m json.tool"
	fi

	local args j; args=() j=1
	for i in "$@"; do
		args[j]="$i" && j=$((j + 1))
		if [[ $i =~ ^-h\|--help$ ]] ; then
			cat <<HELP
resty [host] [options]:

	  Set the host and default options to provided values
HELP
			-resty-help-options
			return 0
		fi
	done

	case "$url" in
	http://*|https://*)
		if [ "${#args[@]}" -ne 0 ]; then
			_RESTY_OPTS="${args[@]}"
		else
			_RESTY_OPTS=""
		fi

		echo "$url" |grep '\*' >/dev/null || url="${url}*"
		_RESTY_HOST="$url"
		_RESTY_DOMAIN=$(echo -n "$_RESTY_HOST" | perl -ape 's@^https?://([^/*:]+):?(\d+)?/.*$@$1_$2@; s/_$//')
		echo "resty host set to: $url"
		;;
	*)
		resty "http://$url" "${args[@]}"
		return
		;;
	esac

	resty-compute-host-option

	[ -z "$_RESTY_NO_HISTORY" ] && resty-save-env
}


function resty-compute-host-option {
	# note: extract a function so it can be manually called if edited file

	if [[ -f "$_RESTY_DIR/resty" ]] ; then
		for method in HEAD OPTIONS GET PATCH POST PUT TRACE DELETE ; do
			eval "export _RESTY_OPT_DEFAULT_$method; _RESTY_OPT_DEFAULT_$method=\"$(cat "$_RESTY_DIR/default" 2>/dev/null\
						| sed 's/^ *//' \
						| grep "^$method" | cut -b $((${#method}+2))-)\""
		done
	else
		for method in HEAD OPTIONS GET PATCH POST PUT TRACE DELETE ; do
			eval "export _RESTY_OPT_DEFAULT_$method; _RESTY_OPT_DEFAULT_$method=\"\""
		done
	fi
	if [[ -f "$_RESTY_DIR/$_RESTY_DOMAIN" ]] ; then
		for method in HEAD OPTIONS GET PATCH POST PUT TRACE DELETE ; do
			eval "export _RESTY_OPT_HOST_$method; _RESTY_OPT_HOST_$method=\"$(cat "$_RESTY_DIR/$_RESTY_DOMAIN" 2>/dev/null\
						| sed 's/^ *//' \
						| grep "^$method" | cut -b $((${#method}+2))-)\""
		done
	else
		for method in HEAD OPTIONS GET PATCH POST PUT TRACE DELETE ; do
			eval "export _RESTY_OPT_HOST_$method; _RESTY_OPT_HOST_$method=''"
		done
	fi
}

function resty-call {
	if [ $# = 0 ] ; then echo "resty-call need args" >&2; return 1; fi

	local method; method="$1"; shift
	if [[ ! "HEAD OPTIONS GET PATCH POST PUT TRACE DELETE" =~ $method ]] ; then # this is not good
		echo "First arg must be an HTTP verb, '$method' isn't" >&2
		return 1
	fi
	for opt in "$@"; do # print help if requested
		if [[ $opt =~ ^-h\|--help$ ]] ; then
			cat <<HELP
$method [path] [options]:

	  Perform a $method request to host $_RESTY_HOST with path and options.
HELP
			-resty-help-options
			return 0
		fi
	done

	local _path __path

	if [ -z "$_RESTY_HOST" ] ;then
		resty-load-env
	fi

	if [ -z "$_RESTY_HOST" ] ;then
		echo "missing host, call resty http://...." >&2
		return 1
	fi

	local cookies="$_RESTY_DIR/cookies/${_RESTY_DOMAIN}"

	local h2t="$_RESTY_H2T"
	local editor="$_RESTY_EDITOR"
	local hasbody
	if [[ "POST PUT TRACE PATCH" =~ $method ]]; then
		hasbody="yes"
	fi

	if [[ "$1" =~ ^/ ]] ; then # retrieve path
		_path="$1"
		shift
	fi
	local body
	if [[ ! "$1" =~ ^- ]] ; then # retrieve data
		body="$1"
		[[ $# -gt 0 ]] && shift
	fi

	local -a all_opts curl_opt curlopt_cmd
	local raw query vimedit quote maybe_query verbose dry_run nopp

	local -a resty_default_arg host_arg;
	for i in $(eval echo "\${_RESTY_OPT_DEFAULT_$method}") ; do resty_default_arg+=("$i") ; done
	for i in $(eval echo "\${_RESTY_OPT_HOST_$method}") ; do host_arg+=("$i") ; done

	for opt in "$@"; do
		all_opts+=($(printf '%q' "$opt"))
	done
	all_opts+=("${resty_default_arg[@]}")
	all_opts+=("${host_arg[@]}")
	[ "${#_RESTY_OPTS[@]}" -ne 0 ] && all_opts+=($(echo ${_RESTY_OPTS} | tr " " "\n"))

	for opt in "${all_opts[@]}"; do
		if [ -n "$maybe_query" ]; then
			if [ -z "$query"]; then
				query="?$opt"
			else
				query="$query&$opt"
			fi
			maybe_query=""
			continue
		fi

		case $opt in
			--verbose|-v) verbose="yes";;
			# TODO; try adapt ; echo "$opt" | grep '^-[a-zA-Z]*v[a-zA-Z]*$' >/dev/null) \
			-V) vimedit="yes" ;;
			-Z) raw="yes" ;;
			-W) ;;
			-Q) quote="yes" ;;
			-q) maybe_query="yes" ;;
			--no-pp) nopp="yes" ;;
			--dry-run) dry_run="yes";;
			-F) curlopt_cmd+=("-H 'Content-Type: multipart/form-data'" "-F") ;;
			--form) curlopt_cmd+=("-H 'Content-Type: multipart/form-data'") ;;
			--json) curlopt_cmd+=("-H 'Accept: application/json'" "-H 'Content-Type: application/json'");;
			--xml) curlopt_cmd+=("-H 'Accept: application/xml'" "-H 'Content-Type: application/xml'") ;;

			*) curlopt_cmd+=("$opt")
		esac
	done

	if [ -z "$quote" ]; then # replace special char with codes
		_path=$(echo "$_path"|sed 's/%/%25/g;s/\[/%5B/g;s/\]/%5D/g;s/|/%7C/g;s/\$/%24/g;s/&/%26/g;s/+/%2B/g;s/,/%2C/g;s/:/%3A/g;s/;/%3B/g;s/=/%3D/g;s/?/%3F/g;s/@/%40/g;s/ /%20/g;s/#/%23/g;s/{/%7B/g;s/}/%7D/g;s/\\/%5C/g;s/\^/%5E/g;s/~/%7E/g;s/`/%60/g')
	fi

	if [ "$RESTY_NO_PRESERVE_PATH" != "true" ]&&[ "$RESTY_NO_PRESERVE_PATH" != "yes" ]; then
		__path="${_path:-${_RESTY_PATH}}"
		_RESTY_PATH="${__path}"
	else
		__path=$_path
	fi

	_path="${_RESTY_HOST//\*/$__path}"

	if [ "$hasbody" = "yes" ] && [ -z "$body" ]; then # treat when no body provided as arg
		if [ ! -t 0 ] ; then # retrieve what stdin hold if stdin open
			body="@-"
		else
			body=""
		fi
	fi

	if [ "$hasbody" = "yes" ] && [ "$vimedit" = "yes" ]; then
		local tmpf; tmpf=$(mktemp)
		[ -t 0 ] || cat >| "$tmpf"
		(exec < /dev/tty; "$editor" "$tmpf")
		body=$(cat "$tmpf")
		rm -f "$tmpf"
	fi

	if [ -n "$body" ] ; then curl_opt="--data-binary" ;fi
	if [ "$method" = "OPTIONS" ] ; then raw="yes" ; fi
	if [ "$method" = "HEAD" ] ; then
		curl_opt="-I"
		raw="yes"
	fi

	# Forge command and display it if dry-run
	local cmd=(curl -sLv $curl_opt $([ -n "$body" ] && printf "%q" "$body") -X $method -b \"$cookies\" -c \"$cookies\" "$(\
		[ -n "$curlopt_cmd" ] && printf '%s ' ${curlopt_cmd[@]})"\"$_path$query\")
	if [ "$dry_run" = "yes" ] ; then
		echo "${cmd[@]}"
		return 0
	fi
echo "${cmd[@]}"
	[ -z "$verbose" ] && echo "$method $_path"

	# Launch command and retrieved streams
	local res out err ret _status outf errf
	outf=$(mktemp --tmpdir resty.${method}.XXXXX) errf="${outf}.err"
	eval "${cmd[@]}" >| "$outf" 2>| "$errf"
	_status=$?; out="$(cat "$outf")"; err="$(cat "$errf")"; rm -f "$outf" "$errf"
	ret=$(sed '/^.*HTTP\/[12]\(\.[01]\)\? [0-9][0-9][0-9]/s/.*\([0-9][0-9][0-9]\).*/\1/p; d' <<< "$err" | tail -n1)

	if [ "$_status" -ne "0" ]; then echo "$err" >&2 ; return $_status ; fi

	if [ -n "$err" ] && [ -n "$verbose" ]; then echo "$err" 1>&2 ; fi

	# post process for display
	local display
	if [ -z "$raw" ] && grep -i '^< \s*Content-Type:  *text/html' >/dev/null <<< "$err"
	then display=$h2t
	else display=cat
	fi
	if [ -n "$out" ]; then out=$(echo "$out" | eval "$display") ; fi

	if [[ "$display" =~ ^lynx ]] || [[ "$display" =~ ^elinks ]] ; then
		out=$(echo "$out" |perl -e "\$host='$(echo "$_RESTY_HOST" |sed 's/^\(https*:\/\/[^\/*]*\).*$/\1/')';" \
								-e "$(cat <<'PERL'
			@a=<>;
			$s=0;
			foreach (reverse(@a)) {
				if ($_ =~ /^References$/) { $s++; }
				unless ($s>0) {
					s/^\s+[0-9]+\. //;
					s/^file:\/\/localhost/$host/;
				}
				push(@ret,$_);
			}
			print(join("",reverse(@ret)))
PERL
			)")
	fi

	if [ -n "$out" ]; then
		if [ -n "$nopp" ]; then
			echo $out
		else
			echo "$out" | $_RESTY_JSON_PRINTER
			if [ "$?" -ne 0 ]; then
				echo "raw output:" >&2
				echo "$out"
			fi
		fi
	fi

	rm -f "$outf" "$errf"

	if [ "$ret" -gt 199 -a "$ret" -lt 300 ]; then
		ret=0
	fi

	return $ret
}

function resty-load-alias(){
	alias HEAD=resty-head OPTIONS=resty-options GET=resty-get POST=resty-post PUT=resty-put
	alias TRACE=resty-trace PATCH=resty-patch DELETE=resty-delete
	# maybe add option?
}

function resty-unload-alias(){
	unalias HEAD OPTIONS GET POST PUT TRACE PATCH DELETE
}

function resty-save-env {
	env | grep _RESTY_ | perl -ape 's/=(.*)$/="$1"/g'> "$_RESTY_DIR/${1-default}"
}

function resty-load-env {
	source "$_RESTY_DIR/${1-default}"
}

function resty-reset-cookies {
	local tgt="${1-$_RESTY_DOMAIN}"
	[ "$tgt" = "ALL" ] && tgt="*"
	[ -n "$tgt" ] && rm -fv $_RESTY_DIR/cookies/$tgt
}

function resty-head {
	resty-call HEAD "$@"
}

function resty-options {
	resty-call OPTIONS "$@"
}

function resty-get {
	resty-call GET "$@"
}

function resty-post {
	resty-call POST "$@"
}

function resty-put {
	resty-call PUT "$@"
}

function resty-patch {
	resty-call PATCH "$@"
}

function resty-delete {
	resty-call DELETE "$@"
}

function resty-trace {
	resty-call TRACE "$@"
}

function -resty-help-options  {
cat <<HELP

	  Options:

	  -Q            Don't URL encode the path.
	  -q <query>    Send query string with the path. A '?' is prepended to
					<query> and concatenated onto the <path>.
	  -W            Don't write to history file (only when sourcing script).
	  -V            Edit the input data interactively in 'vi'. (PUT, PATCH,
					and POST requests only, with data piped to stdin.)
	  -Z            Raw output. This disables any processing of HTML in the
					response.
	  -v            Verbose output. When used with the resty command itself
					this prints the saved curl options along with the current
					URI base. Otherwise this is passed to curl for verbose
					curl output.
	  --dry-run     Just output the curl command.
	  <curl opt>    Any curl options will be passed down to curl.
HELP
}

# With -W option, does not write to history file
[ "$1" = "-W" ] && export _RESTY_NO_HISTORY="/dev/null" && [[ $# -gt 0 ]] && shift
