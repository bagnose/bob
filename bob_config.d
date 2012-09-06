/*
 * Copyright 2012, Graham St Jack.
 *
 * This file is part of bob, a software build tool. 
 *
 * Bob is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * Bob is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with Foobar.  If not, see <http://www.gnu.org/licenses/>.
 */

//
// The bob-config utility. Sets up a build directory from which
// a project can be built from source by the 'bob' utility.
// The built files are all located in the build directory, away from the
// source. Multiple source repositories are supported.
//
// Refer to the example bob.cfg file for details of bob configuration.
//
// Note that bob-config does not check for or locate external dependencies.
// You have to use other tools to check out your source and make sure that
// all the external dependencies of your project are satisfied.
// Often this means a 'prepare' script that unpacks a number of packages
// into a project-specific local directory.
//

import std.string;
import std.getopt;
import std.path;
import std.file;
import std.stdio;

import core.stdc.stdlib;
import core.sys.posix.sys.stat;


//================================================================
// Helpers
//================================================================

//
// Set the mode of a file
//
private void setMode(string path, uint mode) {
    chmod(toStringz(path), mode);
}


alias string[][string] Vars;

enum AppendType { notExist, mustExist, mayExist}

//
// Append some tokens to the named element in vars,
// appending only if not already present and preserving order.
//
private void append(ref Vars vars, string name, string[] extra, AppendType atype) {
    switch (atype) {
    case notExist:
        ensure(name !in vars, "Cannot create variable %s again", name);
        break;
    case mustExist:
        ensure(name in vars, "Cannot add to non-existant variable %s", name);
        break;
    case mayExist:
    }

    if (name !in vars) {
        vars[name] = null;
    }
    foreach (string item; extra) {
        bool got = false;
        foreach (string have; vars[name]) {
            if (item == have) {
                got = true;
                break;
            }
        }
        if (!got) {
            vars[name] ~= item;
        }
    }
}


//
// Return a string array of tokens parsed from a number of environment variables, using ':' as delimiter.
// Duplicated are discarded.
//
string[] fromEnv(string[] variables) {
    string[] result;
    bool[string] present;
    foreach (variable; variables) {
        foreach (token; split(std.process.getenv(variable), ":")) {
            if (token !in present) {
                present[token] = true;
                result ~= token;
            }
        }
    }
    return result;
}


//
// Return a string representing the given tokens as an environment variable declaration
//
string toEnv(string[][Priority] tokens, string name) {
    string result;
    foreach (string[] strings; tokens) {
        foreach (string token; strings) {
            result ~= ":" ~ token;
        }
    }
    if (result && result[0] == ':') {
        result = result[1..$];
    }
    if (result) {
        result = name ~ "=\"" ~ result ~ "\"";
    }
    return result;
}


//================================================================
// Down to business
//================================================================

//
// Set up build environment as specified by config, or issue error messages and bail
//
// repos are repository names in sibling directories to the directory containing
// the configure script.
//
void establishBuldDir() {

    // check that all is well, and bail with an explanation if not
    if (config.reason.length) {
        writefln("Configure FAILED because:\n%s\n", config.reason);
        exit(1);
    }

    writefln("Configure checks completed ok - establishing build directory...");

    // create build directory
    if (!exists(config.buildDir)) {
        mkdirRecurse(config.buildDir);
    }
    else if (!isDir(config.buildDir)) {
        writefln("Configure FAILED because: %s is not a directory", config.buildDir);
        exit(1);
    }

    // create Boboptions file from bobVars
    string bobText;
    foreach (string key, string[] tokens; config.bobVars) {
        bobText ~= key ~ " = ";
        if (key == "C++FLAGS") {
            // C++FLAGS has all of CCFLAGS too
            foreach (token; config.bobVars["CCFLAGS"]) {
                bobText ~= token ~ " ";
            }
        }
        foreach (token; tokens) {
            bobText ~= token ~ " ";
        }
        bobText ~= ";\n";
    }
    update(config, "Boboptions", bobText, false);

    // create version_info.h file
    string versionText;
    versionText ~= "#ifndef VERSION_INFO__H\n";
    versionText ~= "#define VERSION_INFO__H\n";
    versionText ~= "\n";
    versionText ~= "#define PRODUCT_VERSION \"" ~ config.productVersion ~ "\"\n";
    versionText ~= "#define FOREGROUND_IP_COPYRIGHT_NOTICE \"" ~ config.foregroundCopyright ~ "\"\n";
    versionText ~= "#define BACKGROUND_IP_COPYRIGHT_NOTICE \"" ~ config.backgroundCopyright ~ "\"\n";
    versionText ~= "\n";
    versionText ~= "#endif /* VERSION_INFO__H */\n";
    update(config, "version_info.h", versionText, false);

    // set up string for a fix_env bash function
    string fixText =
`# Remove duplicates and empty tokens from a string containing
# colon-separated tokens, preserving order.
function fix_env () {
    local original="${1}"
    local IFS=':'
    local result=""
    for item in ${original}; do
        if [ -z "${item}" ]; then
            continue
        fi
        #echo "item: \"${item}\"" >&2
        local -i found_existing=0
        for existing in ${result}; do
            if [ "${item}" == "${existing}" ]; then
                found_existing=1
                break 1
            fi
        done
        if [ ${found_existing} -eq 0 ]; then
            result="${result:+${result}:}${item}"
        fi
    done
    echo "${result}"
}
`;

    // create environment-run file
    string runEnvText;
    runEnvText ~= "# set up the run environment variables\n\n";
    runEnvText ~= fixText;
    runEnvText ~= `if [ -z "${DIST_PATH}" ]; then` ~ "\n";
    runEnvText ~= `    echo "DIST_PATH not set"` ~ "\n";
    runEnvText ~= "    return 1\n";
    runEnvText ~= "fi\n";
    runEnvText ~= "\n";
    foreach (string key, string[] tokens; config.runVars) {
        runEnvText ~= "export " ~ key ~ `="$(fix_env "`;
        foreach (token; tokens) {
            runEnvText ~= token ~ ":";
        }
        runEnvText ~= `${` ~ key ~ `}")"` ~ "\n";
    }
    runEnvText ~= "unset fix_env\n";
    update(config, "environment-run", runEnvText, false);


    // create environment-build file
    string buildEnvText;
    buildEnvText ~= "# set up the build environment variables\n\n";
    buildEnvText ~= fixText;
    buildEnvText ~=
`if [ ! -z "${DIST_PATH}" ]; then
    echo "ERROR: DIST_PATH set when building"
    return 1
fi
export DIST_PATH="${PWD}/dist"
`;
    foreach (string key, string[] tokens; config.buildVars) {
        buildEnvText ~= "export " ~ key ~ `="$(fix_env "`;
        foreach (token; tokens) {
            buildEnvText ~= token ~ ":";
        }
        buildEnvText ~= `${` ~ key ~ `}")"` ~ "\n";
    }
    buildEnvText ~= "unset fix_env\n";
    buildEnvText ~= "# also pull in the run environment\n";
    buildEnvText ~= "source ./environment-run\n";
    update(config, "environment-build", buildEnvText, false);


    // create build script
    string buildText =
`#!/bin/bash

source ./environment-build

# Rebuild the bob executable if necessary
BOB_SRC="./src/build-tool/bob.d"
BOB_EXE="./.bob/bob"
if [ ! -e ${BOB_EXE} -o ${BOB_SRC} -nt ${BOB_EXE} ]; then
    echo "Compiling build tool."
    dmd -O -gc -w -wi ${BOB_SRC} -of${BOB_EXE}
    if [ $? -ne 0 ]; then
        echo "Failed to compile the build tool..."
        exit 1
    else
        echo "Build tool compiled successfully."
    fi
fi

# Test if we are running under eclipse
# Cause bob to echo commands passed to compiler to support eclipse auto discovery.
# Also change the include directives to those recognised by eclipse CDT.
if [ "$1" = "--eclipse" ] ; then
    shift
    echo "NOTE: What is displayed here on the console is not exactly what is executed by g++"

    ${BOB_EXE} --actions "$@" 2>&1 | sed -re "s/-iquote|-isystem/-I/g"
else
    ${BOB_EXE} "$@"
fi
`;
    update(config, "build", buildText, true);


    // create clean script
    string cleanText =
`#!/bin/bash

if [ $# -eq 0 ]; then
    rm -rf ./dist ./priv ./obj
else
    echo "Failed: $(basename ${0}) does not accept arguments - it cleans everything."
    exit 2
fi
`;
    update(config, "clean", cleanText, true);


    // strings containing common parts of run-like scripts
    string runPrologText =
`#!/bin/bash

export DIST_PATH="${PWD}/dist"
source ./environment-run
exe=$(which "$1" 2> /dev/null)

if [ -z "${exe}" ]; then
    echo "Couldn't find \"$1\"" >&2
    exit 1
fi
export TMP_PATH="$(dirname ${exe})/tmp-$(basename ${exe})"
`;


    // create (exuberant) ctags config file
    string dotCtagsText =
`--langdef=IDL
--langmap=IDL:+.idl
--regex-IDL=/^[ \t]*module[ \t]+([a-zA-Z0-9_]+)/\1/n,module,Namespace/e
--regex-IDL=/^[ \t]*enum[ \t]+([a-zA-Z0-9_]+)/\1/g,enum/e
--regex-IDL=/^[ \t]*struct[ \t]+([a-zA-Z0-9_]+)/\1/c,struct/e
--regex-IDL=/^[ \t]*exception[ \t]+([a-zA-Z0-9_]+)/\1/c,exception/e
--regex-IDL=/^[ \t]*interface[ \t]+([a-zA-Z0-9_]+)/\1/c,interface/e
--regex-IDL=/^[ \t]*typedef[ \t]+[a-zA-Z0-9_:\*<> \t]+[ \t]+([a-zA-Z0-9_]+)[ \t]*;/\1/t,typedef/e
--regex-IDL=/^[ \t]*[a-zA-Z0-9_:]+[ \t]+([a-zA-Z0-9_]+)[ \t]*[;]/\1/v,variable/e
`;
    update(config, ".ctags", dotCtagsText, false);


    // create make-tags script
    string makeCtagsText =
`#!/bin/bash

SOURCE_DIR="src"
TAGS_FILE="tags"

find -H "${SOURCE_DIR}"/* -xdev \( \( -type d -name \.svn \) -prune \
            -o -name \*.cc -o -name \*.h -o -name \*.ccg -o -name \*.hg -o -name \*.hpp -o -name \*.cpp \
            -o -name \*.inl -o -name \*.i \
            -o -name \*.idl \) |
grep -v ".svn" |
# maybe add other grep commands here
ctags -f "${TAGS_FILE}" -h default --langmap="c++:+.hg.ccg.inl.i" --extra=+f+q --c++-kinds=+p --tag-relative=yes --totals=yes --fields=+i -L -
`;
    update(config, "make-tags", makeCtagsText, true);


    // create make-cooked-tags script
    string makeCookedCtagsText =
`#!/bin/bash

SOURCE_DIR="obj"
TAGS_FILE="cooked-tags"

find -H "${SOURCE_DIR}"/* -xdev \( \( -type d -name \.svn \) -prune \
            -o -name \*.cc -o -name \*.h -o -name \*.ccg -o -name \*.hg -o -name \*.hpp -o -name \*.cpp \
            -o -name \*.idl \) |
grep -v ".svn" |
# maybe add other grep commands here
ctags -f "${TAGS_FILE}" -h default --langmap="c++:+.hg.ccg" --extra=+f+q --c++-kinds=+p --tag-relative=yes --totals=yes --fields=+i -L -
`;
    update(config, "make-cooked-ctags", makeCookedCtagsText, true);


    // create test script
    string testText;
    testText ~= runPrologText;
    testText ~=
`
if [ $# -ne 1 ]; then
    echo "The test script doesn't support arguments to test executable." >&2
    echo "Given: ${@}" >&2
    exit 2
fi
declare -i return_value=1

run_test() {
    # remove results and run the test to make some more
    set -o pipefail
    rm -f ${exe}-*

    # Ensure the result file is not zero-length (Bob depends on this)
    echo ${exe} > ${exe}-result
    ${exe}     >> ${exe}-result 2>&1

    # generate passed or failed file
    if [ "$?" != "0" ]; then
        mv ${exe}-result ${exe}-failed
        echo "${exe}-failed:1: error: test failed"
        cat ${exe}-failed
        exit 1
    else
        mv ${exe}-result ${exe}-passed    
        rm -rf ${TMP_PATH}
    fi
}

rm -rf ${TMP_PATH} && mkdir ${TMP_PATH} && run_test
`;
    update(config, "test", testText, true);


    // create run script
    string runText;
    runText ~= runPrologText;
    runText ~= "rm -rf ${TMP_PATH} && mkdir ${TMP_PATH} && exec \"$@\"";
    update(config, "run", runText, true);

    if (config.buildLevel == "profile") {
        // create perf script
        string perfText;
        perfText ~= runPrologText;
        perfText ~= "echo after exiting, run 'perf report' to see the result\n";
        perfText ~= "rm -rf ${TMP_PATH} && mkdir ${TMP_PATH} && exec perf record -g -f $@\n";
        update(config, "perf", perfText, true);
    }

    if (config.buildLevel != "release") {
        // create gdb script
        string gdbText;
        gdbText ~= runPrologText;
        gdbText ~= "rm -rf ${TMP_PATH} && mkdir ${TMP_PATH} && exec gdb --args $@\n";
        update(config, "gdb", gdbText, true);

        // create nemiver script
        string nemiverText;
        nemiverText ~= runPrologText;
        nemiverText ~= "rm -rf ${TMP_PATH} && mkdir ${TMP_PATH} && exec nemiver $@\n";
        update(config, "nemiver", nemiverText, true);
    }

    // create valgrind script
    string valgrindText;
    valgrindText ~= runPrologText;
    valgrindText ~= "rm -rf ${TMP_PATH} && mkdir ${TMP_PATH} && exec valgrind $@\n";
    update(config, "valgrind", valgrindText, true);


    //
    // create src directory with symbolic links to all top-level packages in all
    // specified repositories
    //

    // make src dir
    string srcPath = buildPath(config.buildDir, "src");
    if (!exists(srcPath)) {
        mkdir(srcPath);
    }

    // make a symbolic link to each top-level package in this and other specified repos
    string[string] pkgPaths;  // package paths keyed on package name
    string project = dirName(getcwd);
    foreach (string repoName; otherRepos ~ baseName(getcwd)) {
        string repoPath = buildPath(project, repoName);
        if (isDir(repoPath)) {
            //writefln("adding source links for packages in repo %s", repoName);
            foreach (string path; dirEntries(repoPath, SpanMode.shallow)) {
                string pkgName = baseName(path);
                if (isDir(path) && pkgName[0] != '.') {
                    //writefln("  found top-level package %s", pkgName);
                    assert(pkgName !in pkgPaths,
                           format("Package %s found at %s and %s",
                                  pkgName, pkgPaths[pkgName], path));
                    pkgPaths[pkgName] = path;
                }
            }
        }
    }
    foreach (name, path; pkgPaths) {
        string linkPath = buildPath(srcPath, name);
        system(format("rm -f %s; ln -sn %s %s", linkPath, path, linkPath));
    }

    // print success
    writefln("Build environment in %s is ready to roll", config.buildDir);
}


//
// Parse the config file, returning the variable definitions it contains.
//
Vars parseConfig(string configFile, string mode) {

    enum Section { none, defines, modes, commands }

    int     anchor;
    int     line = 1;
    int     col  = 0;
    Section section = Section.none;
    bool    inMode;
    string  commandType;
    Vars    vars;

    foreach (string line; spitLines(readText(configFile))) {

        // Skip comment lines.
        if (line && line[0] == '#') continue;

        string[] tokens = split(line);

        if (tokens && tokens[0] && tokens[0][0] == '[') {
            // Start of a section
            section = to!Section(tokens[0][1..$-1]);
        }

        else {
            if (section == Section.defines) {
                if (tokens.length >= 2 && tokens[1] == "=") {
                    // Define a new variable.
                    vars.append(tokens[0], tokens[2..$], AppendType.notExist);
                }
            }

            else if (section == Section.modes) {
                if (!tokens) {
                    inMode = false;
                }
                else if (tokens.length == 1 && !isWhite(line[0])) {
                    inMode = tokens[0] == mode;
                }
                else if (isWhite(line[0]) && tokens.length >= 2 && tokens[1] == "+=") {
                    // Add to an existing variable
                    vars.append(tokens[0], tokens[2..$], AppendType.mustExist);
                }
            }

            else if (section == Section.commands) {
                if (!tokens) {
                    commandType = "";
                }
                else if (tokens && !isWhite(line[0]) {
                    commandType = strip(line);
                }
                else if (commandType && tokens && isWhite(line[0])) {
                    vars.append(commandType, strip(line), AppendType.mayExist);
                }
            }
        }
    }

    return vars;
}


//
// Main function
//
int main(string[] args) {

    bool     help;
    string   mode;
    string   desc       = "Development build from " ~ getcwd;
    string   configFile = "bob.cfg";
    string   buildDir;

    //
    // Parse command-line arguments.
    //

    try {
        getopt(args,
               std.getopt.config.caseSensitive,
               "help",   &help,
               "mode",   &mode,
               "config", &configFile,
               "desc",   &desc);
    }
    catch (Exception ex) {
        writefln("Invalid argument(s): %s", ex.msg);
        help = true;
    }

    if (help || args.length != 2 || !mode.length) {
        writefln("Usage: %s [options] build-dir-path\n"
                 "  --help                Display this message.\n"
                 "  --mode=mode-name      Build mode.\n"
                 "  --desc=description    Defines DESCRIPTION.\n"
                 "  --config=config-file  Specifies the config file. Default bob.cfg.\n",
                 args[0]);
        exit(1);
    }

    string buildDir = args[1];
    string srcDir   = getcwd;


    //
    // Read config file and establish build dir.
    //

    Vars vars = parseConfig(configFile, mode);
    establishBuildDir(buildDir, srcDir, desc, vars);

    return 0;
}
