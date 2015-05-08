{ EOL } = require 'os'

{ basename, dirname, resolve } = require 'path'

{ readdirSyncRecursive: findAll } = require 'wrench'

async = require 'async'

merge = require 'lodash.merge'

GitHubApi = require 'github'

ACliCommand = require 'a-cli-command'

class Github extends ACliCommand

  command:

    name: "github"

    options:

      "version":

        type: "string"

        default: "3.0.0"

        description: [
          "the GitHub api version"
        ]

      "timeout":

        type: "number"

        default: 5000

        description: [
          "the GitHub api request timeout"
        ]

      "note":

        type: "string"

        default: "github cli access"

        description: [
          "the note required by the GitHub",
          "authorizations api"
        ]

      "scopes":

        type: "array"

        default: ["user", "repo", "public_repo", "delete_repo", "gist"]

        description: [
          "the requested scopes for the GitHub",
          "authorizations api"
        ]

      "login":

        type: "boolean"

        triggers: ["version", "timeout", "note", "scopes"]

        description: [
          "github account login trigger",
          "in order to create an remove",
          "github repo a oauth token is required",
          "an application token can be created",
          "at "
        ]

      "repo":

        type: "string"

        default: basename(process.cwd())

        description: [
          "the github repository name"
        ]

      "create":

        type: "boolean"

        triggers: [
          "repo",
          "version",
          "timeout",
          "note",
          "scopes",
          "init",
          "license"
        ]

        description: [
          "creates a new github repository"
        ]

      "delete":

        type: "boolean"

        triggers: ["repo", "version", "timeout",  "note", "scopes"]

        description: [
          "deletes a github repository"
        ]

      "init":

        type: "boolean"

        triggers: ["templates"]

        default: true

        description: [
          "calls the init command on create",
          "with the package-init-github template"
        ]

      "templates":

        type: "array"

        default: [ "package-init-github" ]

        description: [
          "specifies with templates should be used",
          "by package-init when using init"
        ]

      "force":

        type: "boolean"

        description: [
          "when using init assumes default values",
          "without prompting for aditional information"
        ]

      "commit":

        type: "boolean"

        triggers: ["origin", "message"]

        description: [
          "when true makes the create trigger",
          "performs add, commit and push on repository",
          "contents to origin master"
        ]

      "origin":

        type: "string"

        default: "master"

        description: [
          "the remote origin name"
        ]

      "message":

        type: "string"

        default: (new Date).toISOString()

        description: [
          "the commit message"
        ]

      "recursive":

        type: "boolean"

        description: [
          "when commit trigger is enabled",
          "finds all npm packages owned by username",
          "and tries to perform commit on all of them"
        ]

      "gh-pages":

        type: "string"

        triggers: [ "repo", "gh-pages-template" ]

        default: resolve "#{process.env.PWD}", "gh-pages"

        description: [
          "gh-pages branch location"
        ]


      "gh-pages-template":

        type: "string"

        default: resolve "#{__dirname}", "gh-pages"

        description: [
          "gh-pages branch template"
        ]

      "license":

        type: "string"

        default: "MIT"

        description: [
          "license applied to the software"
        ]

      "author":

        type: "string"

        description: [
          "the author of the software"
        ]



  data: (github, username) ->

    github.username ?= username

    github.homepage ?= "https://github.com/#{username}"

  basic: (github, callback) ->

    @cli.prompt [{

      type: "input",
      name: "username",
      message: "github username?",
      default: github.username

    },{

      type: "password",
      name: "password"
      message: "github password?"
      validate: (val) -> return val.length > 0

    }], (res) =>

      { username, password } = res

      github.basic = res

      @data github, username

      callback github

  twoFactor: (github, callback) ->

    @cli.prompt [{

      type: "password",
      name: "code",
      message: "github security code?"

    }], (res) =>

      { code } = res

      github.payload.headers = 'X-GitHub-OTP': code

      @authorize github, callback

  authorize: (github, callback) ->

    @api.authorization.create github.payload, (err, response) =>

      if err

        { message, errors } = JSON.parse err.message

        if err.message.match "two-factor"

          return @twoFactor github, callback

        else return callback err, response

      if token = response.token

        delete github.basic

        delete github.payload

        github.authorization = response

        @cli.cache.put "github", github

        @cli.cache.save()

        @cli.console.info "oauth token: #{token}"

        return @authenticate github, callback

      callback err, response

  create: (github, callback) ->

    @basic github, (github) =>

      @api.authenticate

        type: "basic"

        username: github.basic.username

        password: github.basic.password

      github.payload =

        scopes: github.scopes

        note: github.note

        note_url: github.homepage

      @authorize github, callback

  authenticate: (github, callback) ->

    if not github?.authorization?.token

      return @create github, callback

    @api.authenticate

      type: "oauth"

      token: github.authorization.token

    callback null, github

  error: (err, github) ->

    return [

      "something when wrong!",

      "#{JSON.stringify(github, null, 2)}",

      "#{err}"

    ].join EOL

  init: (command, repo, next) ->

    @allRepos = {}

    @isAuthenticated = false

    tmp = resolve pwd(), "tmp-#{repo.name}"

    @exec "git clone #{repo.ssh_url} #{tmp}", (err, res) =>

      if err then return next err, null

      mv resolve("#{tmp}",".git"), pwd()

      rm "-Rf", tmp

      args = [ "init" ]

      { force, templates, commit } = command.args

      if force

        args.push "--force"

      if templates

        args.push "--templates"

        args.push JSON.stringify templates

      @cli.run args, (err, res) =>

        if err then return next err, null

        next err, res

  forceAuthentication: (command, next) ->

    delete command.args.login

    { github } = @cli.cache.get()

    github = merge github or {}, command.args

    @api ?= new GitHubApi github

    @authenticate github, (err, github) =>

      if err then return next @error(err, github), null

      @allRepos = {}

      repos = Object.keys github.repos

      repos.map (r) => @allRepos[r] = true

      @isAuthenticated = true

      next null, github

  commit: (message, origin, next) ->

    @exec "git add .", (err, res) =>

      if err then return next null, err

      @exec "git commit -am '#{message}'", (err, res) =>

        if err then return next null, err

        @exec "git push origin #{origin}", next

  getAllRepos: (pwd=process.env.PWD, blacklist={}) ->

    repos = []

    blacklist = {}

    { github } = @cli.cache.get()

    { username } = @cli.cache.get "github"

    { repos: whitelist } = @cli.cache.get "github"

    findAll(pwd).map (file) =>

      if file.match(/package.json$/) isnt null

        try

          file = "#{pwd}/#{file}"

          pkg = require(file)

          if not whitelist[pkg.name] then return null

          if blacklist[pkg.name] then return null

          url = pkg?.repository?.url or ''

          if url.match(username) isnt null

            blacklist[pkg.name] = true

            repos.push dirname(file)

        catch err

    repos

  license: (command, next) ->

    @shell

    _license = (l, a, done) =>

      lfile = "#{process.cwd()}/LICENSE.txt"

      pkg.license = l or "MIT"

      if l is "MIT"

        y = new Date().getFullYear()

        """
        The MIT License (MIT)

        Copyright (c) #{y} #{a}

        Permission is hereby granted, free of charge, to any person obtaining a copy
        of this software and associated documentation files (the "Software"), to deal
        in the Software without restriction, including without limitation the rights
        to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
        copies of the Software, and to permit persons to whom the Software is
        furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in
        all copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
        IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
        FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
        AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
        LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
        OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
        THE SOFTWARE.
        """.to lfile

      @cli.console.info "created license file: #{lfile}"

      done()

    file = "#{process.cwd()}/package"

    pkg = require file

    { license, author } = command.args

    { github } = @cli.cache.get()

    { username } = @cli.cache.get "github"

    options =

      url: "https://api.github.com/users/#{username}"

      headers:

        'User-Agent': 'spaghetty'

    request = require 'request'

    request options, (err, response, body) ->

      { name: author } = JSON.parse(body)

      pkg.author = author

      _license license, author, () ->

        JSON.stringify(pkg, null, 2).to "#{file}.json"

        next null, "license"

  ghPages: (command, next) ->

    { github } = @cli.cache.get()
    { username } = @cli.cache.get "github"
    repo = command.args.repo
    repoUrl = "git@github.com:#{username}/#{repo}.git"
    template = command.args['gh-pages-template']
    dir = command.args['gh-pages']

    cmds = [
      "mkdir #{dir}",
      "git clone #{repoUrl} #{dir}/#{repo}",
      "cd #{dir}/#{repo}",
      "mv #{dir}/#{repo}/.git #{dir}",
      "cp -R #{template}/* #{dir}/",
      "rm -Rf #{dir}/#{repo}",
      "git -C #{dir} checkout --orphan gh-pages",
      "git -C #{dir} add .",
      "git -C #{dir} commit -am \"gh-pages\"",
      "git -C #{dir} push origin gh-pages"
    ]

    _series = () =>

      cmd = cmds.shift()

      if not cmd

        return next null, "gh-pages created successfully!"

      @exec cmd, (err, res) =>

        if err then return next null, err

        _series()

    _series()

  delete: (command, next) ->

    @shell

    { repo } = command.args

    { github } = @cli.cache.get()

    github = merge github or {},  command.args

    delete github.delete

    delete github.repo

    delete github.login

    @cli.prompt [{

      type: "confirm"

      name: "confirmed"

      message: [

        "are you shure you want"

        "to delete #{github.username}/#{repo}?"

      ].join EOL

    }], (response) =>

      if response.confirmed

        @api ?= new GitHubApi github

        @authenticate github, (err, github) =>

          if err then return next @error(err, github), null

          user = github.username

          payload =

            "user": "#{user}"

            "repo": "#{repo}"

          @api.repos.delete payload, (err, response) =>

            message = "#{user}/#{repo}"

            if data = github?.repos?[repo]

              delete github.repos[repo]

              @cli.cache.put 'github', github

              @cli.cache.save()

            data ?= message

            rm "-Rf", resolve(pwd(), ".git")

            pkgfile = resolve(pwd(), 'package.json')

            if test "-e", pkgfile

              pkg = JSON.parse cat pkgfile

              delete pkg.bugs

              delete pkg.repository

              delete pkg.homepage

              JSON.stringify(pkg, null, 2).to pkgfile

            @cli.console.error message

            next null, data

  "license?": (command, next) ->

    if command.args.recursive

      @shell

      repos = @getAllRepos()

      _series = () =>

        repo = repos.shift()

        if not repo then return next null, "license"

        cd repo

        @license command, (err, res) =>

          if err then return next null, err

          _series()

      _series()

    else

      @license command, (err, res) =>

        if err then return next null, err

        next null, "license"


  "gh-pages?": (command, next) ->

    @ghPages command, next

  "commit?": (command, next) ->

    { origin, recursive, message } = command.args

    if not recursive then return @commit message, origin, next

    @shell

    repos = @getAllRepos()

    commitFn = (res, done) =>

      dir = repos.shift()

      if dir

        cd dir

        @commit message, origin, (e, r) =>

          if e then res.push e else res.push "#{dir}#{EOL}#{EOL}#{r}"

          commitFn res, done

      else

        done null, res

    commitFn [], (err, res) =>

      next null, res.join EOL


  "login?": (command, next) ->

    if not @isAuthenticated then @forceAuthentication(

      command, next

    )

  "create?": (command, next) ->

    @shell

    { repo } = command.args

    { github } = @cli.cache.get()

    github = merge github or {},  command.args

    delete github.create

    delete github.repo

    delete github.login

    delete github.init

    delete github.templates

    delete github.force

    delete github.commit

    @api ?= new GitHubApi github

    @authenticate github, (err, github) =>

      if err then return next @error(err, github), null

      payload = { "name": repo }

      @api.repos.create payload, (err, response) =>

        if err then return next @error(err, response), null

        if response.id

          github.repos ?= {}

          github.repos[response.name] = response

          @cli.cache.put "github", github

          @cli.cache.save()

          user = github.username

          @init command, response, (err, res) =>

            @cli.console.info "#{user}/#{repo}"

            next null, response

  "delete?": (command, next) ->

    @delete command, (err, res) ->

      next err, res

module.exports = Github
