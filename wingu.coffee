aws2js = require 'aws2js'
exec = require('child_process').exec
fs = require 'fs'
Levenshtein = require 'levenshtein'
moment = require 'moment'
Parser = require('xml2js').Parser
request = require 'request'
_ = require 'underscore'
util = require 'util'

# Parses & manipulates version information.
class Version

    # Creates a Version from a string of the form v1.1.1-20110101 or v1.1.1.
    constructor: (@tag) ->
        match = tag.match /v?([0-9\.]+)(-(\d+)(-(\w+))?)?\/?$/
        if match
            @name = match[1]
            @name = "0#{@name}" if @name.match(/^\./)
            @date = match[3]
            @extras = match[5]
            @valid = true
        else
            @valid = false

    # Splits the version number into an array of its parts -- for example,
    # v1.1.1 -> [1, 1, 1].
    parts: ->
        parseInt v for v in @name.split '.'

    # Returns a new version representing the version after this one. The
    # increment parameter determines which level of the version is increased.
    next: (increment = 0) ->
        parts = @.parts()
        parts.pop() for i in [0...increment]
        bump = parts.pop()
        parts.push(bump + 1)
        parts.push(0) for i in [0...increment]
        new Version parts.join('.')

    # Returns the canonical string representation of this Version.
    toString: ->
        if not @valid
            return 'unknown'
        parts = ["v#{@name}"]
        parts.push "(#{@date})" if @date
        parts.push @extras if @extras
        parts.join ' '

class Tag
    constructor: (@name, @commit) ->
        @date = moment(@commit.date).format('ddd, MMM D YYYY')
        @author = @commit.author
        @revision = parseInt commit['@'].revision
        @version = new Version @name

    join: (tag) ->
        @next = tag
        tag

    since: ->
        moment(@commit.date).fromNow()

    range: ->
        if @.next
            "r#{@.next.revision}-r#{@.revision}"
        else
            "-r#{@.revision}"

    toString: ->
        "#{@.name} by #{@.author}, #{@.since()} on #{@.date} (#{@.range()})"

class SVN
    constructor: (config) ->
        _.extend(@, config)
        @cache = {}

    get: (subcommand, cb) ->
        cached = @cache[subcommand]
        if not cached or cached.time.diff() < (5 * -60000)
            command = "/usr/bin/svn #{subcommand} --username #{@user} --password #{@password}"
            exec command, (err, stdout, stderr) =>
                @cache[subcommand] = {time: moment(), err: err, stdout: stdout, stderr: stderr}
                cb err, stdout, stderr
        else
            cb cached.err, cached.stdout, cached.stderr

    getObject: (subcommand, cb) ->
        @.get "#{subcommand} --xml", (err, stdout, stderr) ->
            return cb {err: stderr}, null if err
            Util.parseXML stdout, (err, parsed) ->
                return cb {err: err}, null if err
                cb null, parsed

    ls: (relurl, cb) ->
        @.getObject "ls #{@repository}/#{relurl}", cb

    log: (relurl, cb) ->
        @.getObject "log #{@repository}/#{relurl}", cb

    _sortedByDate: (list) ->
        Util.sorted list, (a, b) ->
            moment(b.commit.date).valueOf() - moment(a.commit.date).valueOf()

    withAppVersion: (cb) ->
        @.get "cat #{@repository}/trunk/webapp/application.properties", (err, stdout, stderr) ->
            match = stdout.match(/app.version=(.*)/)
            cb (err or not match), new Version(match[1])

    withAllTags: (cb) ->
        @.ls 'tags', (err, parsed) =>
            lastTag = null
            result = []
            for entry in @._sortedByDate parsed.list.entry
                tag = new Tag entry.name, entry.commit
                if lastTag and tag.version.name != lastTag.version.name
                    lastTag = lastTag.join tag
                    result.push tag
                else if not lastTag
                    lastTag = tag
                    result.push tag
            cb result

    withMatchingTag: (match, cb) ->
        @.withAllTags (tags) ->
            for tag in tags
                return cb tag if match tag
            cb()

    withFirstTag: (cb) ->
        matcher = (tag) -> true
        @.withMatchingTag matcher, cb

    withVersionTag: (version, cb) ->
        matcher = (tag) -> version == (new Version tag.name).name
        @.withMatchingTag matcher, cb

    withCommits: (branch, r1, r2, cb) ->
        @.log "#{branch} -r#{r1}:#{r2}", (err, entries) ->
            cb entries.logentry

class HTTP
    constructor: (config) ->
        _.extend(@, config)
        @cache = {}

    retrieve: (relurl, cb) ->
        cached = @cache[relurl]
        if not cached or cached.time.diff() < (5 * -60000)
            url = @url.replace '//', "//#{@user}:#{@password}@"
            request {uri: "#{url}/#{relurl}"}, (err, resp, body) =>
                parsed = JSON.parse(body)
                @cache[relurl] = {time: moment(), err: err, parsed: parsed}
                cb err, parsed
        else
            cb cached.err, cached.parsed

class Jira extends HTTP
    issue: (name, cb) ->
        @.retrieve "issue/#{name}.json", (err, parsed) ->
            cb err, parsed.fields

class ReviewBoard extends HTTP
    requests: (cb) ->
        @.retrieve 'review-requests', (err, parsed) ->
            cb err, @._sortedByLastUpdate parsed

    _sortedByLastUpdate: (list) ->
        Util.sorted list, (a, b) ->
            moment(a.last_updated).valueOf() - moment(b.last_updated).valueOf()


class EC2
    constructor: (config) ->
        @ec2 = aws2js.load 'ec2'
        @ec2.setCredentials config.id, config.secret
        @ec2.setRegion config.region
        @cache = {}

    nameFromTags: (tagSet) ->
        if not tagSet.item.length
            tagSet.item.value
        else
            _.uniq(item.value for item in tagSet.item when item.key == 'Name')[0]

    call: (action, params, cb) ->
        cachekey = action + _.keys(params).join(' ') + _.values(params).join(' ')
        cached = @cache[cachekey]
        if not cached or cached.time.diff() < (5 * -60000)
            @ec2.call action, params, (err, response) =>
                @cache[cachekey] = {time: moment(), err: err, response: response}
                cb err, response
        else
            cb cached.err, cached.response

    instances: (cb) ->
        @.call 'DescribeInstances', {}, cb

class S3
    constructor: (config) ->
        @s3 = aws2js.load 's3'
        @s3.setCredentials config.id, config.secret
        @cache = {}

    get: (path, handler, cb) ->
        cached = @cache[path]
        if not cached or cached.time.diff() < (5 * -6000)
            @s3.get path, handler, (err, response) =>
                @cache[path] = {time: moment(), err: err, response: response}
                cb err, response
        else
            cb cached.err, cached.response

    buckets: (cb) ->
        @.get '/', 'xml', cb

    bucket: (name, cb) ->
        @.get "/#{name}", 'xml', cb

class Release
    constructor: (@version, @author, @rawdate) ->
        @date = @rawdate.format('ddd MMM Do')

    since: ->
        @rawdate.fromNow()

    toString: ->
        "#{@.author} is releasing #{@.version} on #{@.date}, #{@.since()}"

class Releases
    constructor: (@svn, config) ->
        _.extend(@, config)

    list: (days, cb) ->
        @svn.withAllTags (tags) =>
            result = []
            tagstart = tags.shift()
            next = {date: moment(), author: tagstart.author, version: new Version tagstart.name}
            for i in [1..days] # TODO fix when running on a release day
                tag = tags.shift()
                next.author = @engineers[(_.indexOf(@engineers, next.author) + 1) % @engineers.length]
                next.version = next.version.next()

                validday = null
                for j in [1...7]
                    if next.date.add('days', 1).format('dddd') in @days
                        validday = moment(next.date.valueOf())
                        break
                result.push new Release(next.version, next.author, validday)
            cb result

class Loader
    constructor: (@configFile) ->
        @modules = []

    add: (name, load) ->
        @modules.push({name: name, load: load})

    meld: (robot) ->
        @config = JSON.parse fs.readFileSync(@configFile)
        for module in @modules
            @[module.name] = module.load @config, @
        robot.plugins = @

    eachService: (cb) ->
        for module in @modules
            cb module.name, @[module.name]

# ------------------------------------------------------------

plugins = new Loader process.env.PLUGIN_CONFIG
plugins.add 'jira', (config, loader) -> new Jira config.jira
plugins.add 'rb', (config, loader) -> new ReviewBoard config.reviewboard
plugins.add 'svn', (config, loader) -> new SVN config.svn
plugins.add 'ec2', (config, loader) -> new EC2 config.aws
plugins.add 's3', (config, loader) -> new S3 config.aws
plugins.add 'releases', (config, loader) -> new Releases plugins.svn, config.releases

# ------------------------------------------------------------

Util =
    parseXML: (text, cb) ->
        new Parser().parseString text, cb

    plural: (count, word, suffix = 's') ->
        if count == 1
            "#{count} #{word}"
        else
            "#{count} #{word}#{suffix}"

    sorted: (list, fn) ->
        list.sort(fn)
        list

    list: (item) ->
        if item.length?
            item
        else
            [item]

module.exports = (robot) ->

    plugins.meld robot

    # --------------------------------------------------

    robot.respond /flush caches/i, (msg) ->
        flushed = []
        robot.plugins.eachService (name, instance) ->
            instance.cache = {}
            flushed.push(name)
        msg.send "flushed #{flushed.join(', ')}"

    robot.respond /reload/i, (msg) ->
        plugins.meld robot
        msg.send "reloaded"

    # --------------------------------------------------

    robot.respond /(.*) current version\??$/i, (msg) ->
        svn = robot.plugins.svn
        svn.withAppVersion (err, version) ->
            return msg.send "I don't know what the current version is" if err
            msg.send "the current version is #{version.name}"

    robot.respond /((all)|(last ?(\d+)?)) tags?/i, (msg) ->
        svn = robot.plugins.svn
        all = msg.match[2]
        amount = parseInt(msg.match[4] or "1")
        svn.withAllTags (tags) ->
            limit = if all then tags.length else amount
            for tag in tags[0...limit]
                msg.send tag.toString()

    robot.respond /tag for ([0-9\.]+)/i, (msg) ->
        svn = robot.plugins.svn
        version = msg.match[1]
        svn.withVersionTag version, (tag) ->
            return msg.send "I don't know about #{version}" if not tag
            msg.send tag.toString()

    robot.respond /commits for (([0-9\.]+)|(current))/i, (msg) ->
        svn = robot.plugins.svn
        version = msg.match[1]

        summarizeRange = (commits) ->
            known = []
            unknown = 0
            for commit in commits
                match = /[A-Z]{3,}\-\d+/.exec commit.msg
                if match
                    known.push match[0]
                else
                    unknown += 1
            issues = Util.sorted(_.uniq(known)).join ', '
            msg.send "#{commits.length} total commits, including #{issues} and #{unknown} unknown"

        if version == 'current'
            svn.withFirstTag (tag) ->
                svn.withCommits 'trunk', tag.revision, 'HEAD', summarizeRange
        else
            svn.withVersionTag version, (tag) ->
                return msg.send "I don't know about #{version}" if not tag
                svn.withCommits 'trunk', tag.next.revision, tag.revision, summarizeRange

    # --------------------------------------------------

    robot.respond /(.* )?the next (\d+ )?releases?\??/i, (msg) ->
        releases = robot.plugins.releases
        amount = parseInt(msg.match[2] or "1")
        releases.list amount, (releases) ->
            return msg.send "I don't know the release schedule" if not releases
            for r in releases
                msg.send r.toString()

    robot.respond /(.* )?my next release\??/i, (msg) ->
        releases = robot.plugins.releases
        releases.list releases.engineers.length, (releases) ->
            for r in releases
                continue unless r.author == msg.user
                return msg.send r.toString()
            msg.send "#{msg.user}, I don't know when your next release is"

    # --------------------------------------------------

    robot.respond /(.* )?(jira|issue) ([A-Z]{3,})?-?(\d+)\??/i, (msg) ->
        jira = robot.plugins.jira
        project = msg.match[3] or 'ELEMENTS'
        id = msg.match[4]
        jira.issue "#{project}-#{id}", (err, issue) ->
            summary = issue.summary.value
            reporter = issue.reporter.value.name
            assignee = issue.assignee.value.name
            status = issue.status.value.name
            msg.send "#{summary}, reported by #{reporter}, assigned to #{assignee}, currently #{status}"

    # --------------------------------------------------

    robot.respond /(code )?reviews/i, (msg) ->
        rb = robot.plugins.rb
        rb.requests (err, requests) ->
            msg.send "there are #{Util.plural requests.total_results, 'open review request'}"
            return if requests.total_results < 0
            for request in requests.review_requests[..2]
                summary = request.summary
                title = request.links.submitter.title
                since = moment(request.last_updated).fromNow()
                msg.send "'#{summary}' by #{title}, #{since}"

    robot.respond /my (code )?reviews/i, (msg) ->
        rb = robot.plugins.rb
        rb.requests (err, requests) ->
            count = 0
            for request in requests.review_requests
                continue unless request.links.submitter.title == msg.user
                summary = request.summary
                title = request.links.submitter.title
                since = moment(request.last_updated).fromNow()
                msg.send "'#{summary}' by #{title}, #{since}"
                count++
            msg.send "#{msg.user} has no pending reviews" if not count

    # --------------------------------------------------

    robot.respond /(machines|instances)/i, (msg) ->
        ec2 = robot.plugins.ec2
        ec2.instances (err, response) ->
            instances = {}
            for item in response.reservationSet.item
                name = ec2.nameFromTags(item.instancesSet.item.tagSet)
                state = item.instancesSet.item.instanceState.name
                if not instances[state]?
                    instances[state] = []
                instances[state].push(name)
            for status, list of instances
                msg.send "#{Util.plural list.length, status + ' instance'}: #{list.join ', '}"

    robot.respond /ip of ([a-zA-Z_0-9 ]+)/i, (msg) ->
        ec2 = robot.plugins.ec2
        ec2.instances (err, response) ->
            for item in response.reservationSet.item
                item = item.instancesSet.item
                name = ec2.nameFromTags(item.tagSet)
                if name == msg.match[1]
                    msg.send "#{name} has IP address #{item.ipAddress}"

    # --------------------------------------------------

    robot.respond /buckets/i, (msg) ->
        s3 = robot.plugins.s3
        s3.buckets (err, response) ->
            buckets = []
            for bucket in Util.list(response.Buckets)
                buckets.push bucket.Bucket.Name
            msg.send buckets.join(', ')

    # --------------------------------------------------
    
    robot.respond /who knows about ([^?]+)\??/i, (msg) ->
        what = msg.match[1].trim()
        result = {}
        for user in _.values(robot.users())
            if user.knowledge?
                for item in user.knowledge
                    l = new Levenshtein(what, item)
                    if l < 4
                        if not result[user.name]?
                            result[user.name] = []
                        result[user.name].push(item)
        if not _.isEmpty(result)
            _.each result, (knowledge, user) ->
                msg.send "#{user} knows about #{knowledge.join(', ')}"
        else
            msg.send "nobody knows about #{what}"

    robot.respond /(I|([a-z]+)) knows? about (.*)/i, (msg) ->
        who = if msg.match[1].toUpperCase() == 'I' then msg.user else msg.match[1]
        unless who is 'who'
            what = (item.trim() for item in msg.match[3].split /,/)
            if user = robot.userForName who
                user.knowledge = _.union(user.knowledge or [], what)
                msg.send "hey everyone, #{who} knows about #{what}!"
            else
                msg.send "I don't know who #{who} is"

    robot.respond /(I|([a-z]+)) forgot about (.*)/i, (msg) ->
        who = if msg.match[1].toUpperCase() == 'I' then msg.user else msg.match[1]
        unless who is 'who'
            what = (item.trim() for item in msg.match[3].split /,/)
            if user = robot.userForName who
                user.knowledge = _.difference(user.knowledge or [], what)
                msg.send "bummer, #{who} forgot about #{what}"
            else
                msg.send "I don't know who #{who} is"

    # --------------------------------------------------
    
    robot.respond /([a-zA-Z0-9._-]+) runs ([a-zA-Z0-9._-]+)( ([a-zA-Z0-9._-]+))?/i, (msg) ->
        machine = msg.match[1]
        service = msg.match[2]
        version = msg.match[4]
        machines = robot.brain.data.machines or {}
        if not machines[machine]?
            machines[machine] = {}
        if not machines[machine][service]?
            machines[machine][service] = {}
        machines[machine][service] = {version: version}
        robot.brain.data.machines = machines
        msg.send "got it"

    robot.respond /what runs on ([a-zA-Z0-9._-]+)\??/i, (msg) ->
        machine = msg.match[1]
        machines = robot.brain.data.machines or {}
        if machines[machine]?
            result = []
            _.each machines[machine], (version, service) ->
                result.push(if version then "#{service} #{version}" else service)
            msg.send "#{machine} runs #{result.join(', ')}"
        else
            msg.send "I don't know"
