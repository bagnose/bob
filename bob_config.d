/*
 * Copyright 2012-2013, Graham St Jack.
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
// a project can be built from source by the 'bob' build utility.
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
import std.process;
import std.conv;
import std.ascii;

import core.stdc.stdlib;
import core.sys.posix.sys.stat;

// TODO
// * Use the new std.process module when it becomes available to
//   do all the interaction with environment variables.
// * Port to Windows.
// * Add checking for external dependencies.

//================================================================
// Helpers
//================================================================

//
// Set the mode of a file
//
private void setMode(string path, uint mode) {
    chmod(toStringz(path), mode);
}


//
// Storage for data read from the config file
//
alias string[][string] Vars;


//
// Enum to control how to append to variables
//
enum AppendType { notExist, mustExist, mayExist}


//
// Append some tokens to the named element in vars,
// optionally not appending if already present, and preserving order.
//
private void append(ref Vars vars, string name, string[] extra, AppendType appendType) {
    final switch (appendType) {
    case AppendType.notExist:
        assert(name !in vars, format("Cannot create variable '%s' again", name));
        break;
    case AppendType.mustExist:
        assert(name in vars, format("Cannot add to non-existant variable '%s'", name));
        break;
    case AppendType.mayExist:
    }

    if (name !in vars) {
        vars[name] = null;
    }
    foreach (string item; extra) {
        bool got = false;
        if (appendType != AppendType.notExist) {
            foreach (string have; vars[name]) {
                if (item == have) {
                    got = true;
                    break;
                }
            }
        }
        if (!got) {
            vars[name] ~= item;
        }
    }
    //writefln("%s = %s", name, vars[name]);
}


//
// Return a string to set an environment variable from a bob variable.
//
string toEnv(string envName, const ref Vars vars, string varName, string[] extras) {
    string result;
    bool[string] got;
    string[] candidates = extras;
    if (varName in vars) {
        candidates ~= vars[varName];
    }
    foreach (token; candidates) {
        if (token !in got) {
            got[token] = true;
            result ~= token ~ ":";
        }
    }
    if (result) {
        result = envName ~ "=\"" ~ result[0..$-1] ~ "\"\n";
    }
    return result;
}


//
// Return an array of strings parsed from an environment variable.
//
string[] fromEnv(string varname) {
    return split(std.process.getenv(varname), ":");
}


//
// Write content to path if it doesn't already match, creating the file
// if it doesn't already exist. The file's executable flag is set to the
// value of executable.
//
void update(string path, string content, bool executable) {
    if (!exists(path) || content != readText(path)) {
        std.file.write(path, content);
    }

    uint mode = executable ? octal!744 : octal!644;
    uint attr = getAttributes(path);
    if (attr != mode) {
        setMode(path, mode);
    }
}


//================================================================
// Down to business
//================================================================

//
// Set up build directory.
//
void establishBuildDir(string buildDir, string srcDir, const Vars vars) {

    // Create build directory.
    if (!exists(buildDir)) {
        mkdirRecurse(buildDir);
    }
    else if (!isDir(buildDir)) {
        writefln("%s is not a directory", buildDir);
        exit(1);
    }


    // Create Boboptions file from vars.
    string bobText;
    foreach (string var; vars.keys().sort) {
        const string[] tokens = vars[var];
        if (tokens.length) {
            bobText ~= var ~ " =";
            foreach (token; tokens) {
                bobText ~= " " ~ token;
            }
            bobText ~= '\n';
        }
    }
    update(buildPath(buildDir, "Boboptions"), bobText, false);


    // Create clean script.
    update(buildPath(buildDir, "clean"), "rm -rf ./dist ./priv ./obj ./tmp\n", true);


    // Create environment file.
    string lib  = buildPath(buildDir, "dist", "lib");
    string bin  = buildPath(buildDir, "dist", "bin");
    string data = buildPath(buildDir, "dist", "data");
    string env  = buildPath(buildDir, "environment");
    string envText;
    envText ~= "#!/bin/bash\n";
    envText ~= toEnv("LD_LIBRARY_PATH", vars, "SYS_LIB",  [lib] ~ fromEnv("LD_LIBRARY_PATH"));
    envText ~= toEnv("PATH",            vars, "SYS_PATH", [bin] ~ fromEnv("PATH"));
    envText ~= "DIST_DATA_PATH=\"" ~ data ~ "\"\n";
    update(env, envText, false);


    // Create run script
    update(buildPath(buildDir, "run"),
           "#!/bin/bash\nsource " ~ env ~ "\nexec \"$@\"\n",
           true);


    //
    // Create src directory with symbolic links to all top-level packages in all
    // specified repositories.
    //

    // Make clean src dir.
    string localSrcPath = buildPath(buildDir, "src");
    if (exists(localSrcPath)) {
        rmdirRecurse(localSrcPath);
    }
    mkdir(localSrcPath);

    // Make a symbolic link to each top-level package in this and other specified repos.
    // Note - a package is a dir in a refer statement in a top-level Bobfile, starting
    // from the project package.

    assert("PROJECT" in vars && vars["PROJECT"].length, "PROJECT variable is not set");
    string project = vars["PROJECT"][0];
    string[] repoPaths = [srcDir];
    if ("REPOS" in vars) {
        foreach (path; vars["REPOS"]) {
            repoPaths ~= buildPath(srcDir, path);
        }
    }

    string[string] pkgPaths;

    // Local function to get and check references from a dir's Bobfile
    void getReferences(string path) {
        if (!exists(path) || !isDir(path)) {
            writefln("No directory at %s", path);
            exit(1);
        }
        string bobfile = buildPath(path, "Bobfile");
        if (!exists(bobfile)) {
            writefln("Cannot find Bobfile in %s", path);
            exit(1);
        }
        string[] lines = splitLines(readText(bobfile));
        bool inRefer;
        foreach(line; lines) {
            string[] tokens = split(line);
            if (tokens.length > 0 && tokens[0] == "refer") {
                inRefer = true;
                tokens = tokens[1..$];
            }
            if (inRefer) {
                foreach (token; tokens) {
                    if (token[$-1] == ';') {
                        inRefer = false;
                        token = token[0..$-1];
                    }

                    if (token.length > 0) {
                        string pkgName = token;
                        if (pkgName !in pkgPaths) {
                            string pkgPath;
                            foreach (dir; repoPaths) {
                              string tryPath = buildPath(dir, pkgName);
                              if (isDir(tryPath)) {
                                  if (pkgPath == null) {
                                    pkgPath = tryPath;
                                  }
                                  else {
                                      writefln("Found package %s in both %s and %s",
                                               pkgName, pkgPath, tryPath);
                                      exit(1);
                                  }
                              }
                            }
                            if (pkgPath is null) {
                                writefln("Could not find package %s referenced from %s",
                                         pkgName, bobfile);
                                exit(1);
                            }
                            else {
                                pkgPaths[pkgName] = pkgPath;
                                getReferences(pkgPath);
                            }
                        }
                    }

                    if (!inRefer) break;
                }
            }
        }
    }

    string projectPath = buildPath(srcDir, project);
    pkgPaths[project] = projectPath;
    getReferences(projectPath);

    foreach (name, path; pkgPaths) {
        string linkPath = buildPath(localSrcPath, name);
        system(format("ln -sfn %s %s", path, linkPath));
    }

    // print success
    writefln("Build environment in %s is ready to roll.", buildDir);
}


//
// Parse the config file, returning the variable definitions it contains.
//
Vars parseConfig(string configFile, string mode) {

    enum Section { none, defines, modes, syslibs }

    Section section = Section.none;
    bool    inMode;
    bool    foundMode;
    string  commandType;
    Vars    vars;
    size_t  syslibNum;

    if (!exists(configFile)) {
        writefln("Could not file config file %s", configFile);
        exit(1);
    }

    string content = readText(configFile);
    foreach (string line; splitLines(content)) {

        // Skip comment lines.
        if (!line.length || line[0] == '#') continue;

        //writefln("Processing line: %s", line);

        if (line.length && line[0] == '[' && line[$-1] == ']') {
            // Start of a section
            section = to!Section(line[1..$-1]);
            //writefln("Entered section %s", to!string(section));
        }

        else {
            if (section == Section.defines) {
                string[] tokens = split(line, " =");
                if (tokens.length == 2) {
                    // Define a new variable.
                    vars.append(strip(tokens[0]), split(tokens[1]), AppendType.notExist);
                }
            }

            else if (section == Section.modes) {
                if (!line.length) {
                    // Blank line - mode ended.
                    inMode = false;
                }
                else if (!isWhite(line[0])) {
                    // We are in a mode, which might be the one we want.
                    inMode = strip(line) == mode;
                    if (inMode) {
                        foundMode = true;
                        //writefln("Found mode %s", mode);
                    }
                }
                else if (inMode) {
                    // Add to an existing variable
                    string[] tokens = split(line, " +=");
                    if (tokens.length == 2) {
                        vars.append(strip(tokens[0]), split(tokens[1]), AppendType.mustExist);
                    }
                }
            }

            else if (section == Section.syslibs) {
                string[] tokens = split(line, " =");
                if (tokens.length == 2) {
                    // Define a new variable.
                    vars.append(format("syslib%02d %s", ++syslibNum, strip(tokens[0])),
                                split(tokens[1]),
                                AppendType.notExist);
                }
            }
        }
    }

    if (!foundMode) {
        writefln("Could not find mode %s in config file", mode);
        exit(1);
    }

    return vars;
}


//
// Main function
//
int main(string[] args) {

    //
    // Parse command-line arguments.
    //

    bool     help;
    string   mode;
    string   configFile = "bob.cfg";

    try {
        getopt(args,
               std.getopt.config.caseSensitive,
               "help",   &help,
               "mode",   &mode,
               "config", &configFile);
    }
    catch (Exception ex) {
        writefln("Invalid argument(s): %s", ex.msg);
        help = true;
    }

    if (help || args.length != 2 || !mode.length) {
        writefln("Usage: %s [options] build-dir-path\n"
                 "  --help                Display this message.\n"
                 "  --mode=mode-name      Build mode.\n"
                 "  --config=config-file  Specifies the config file. Default bob.cfg.\n",
                 args[0]);
        exit(1);
    }

    string buildDir = args[1];
    string srcDir   = getcwd();


    //
    // Read config file and establish build dir.
    //

    Vars vars = parseConfig(configFile, mode);
    vars["SRCDIR"] = [srcDir];
    establishBuildDir(buildDir, srcDir, vars);

    return 0;
}
