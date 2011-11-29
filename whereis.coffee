# Simple module to tell where people are.
# TODO: hook it up to gmail and whereami
# TODO: allow people to give permission to use gcal to guess at current location.

module.exports = (robot) ->

  robot.respond /where is ([\w .-]+)\?*$/i, (msg) ->
    whereiswho = msg.match[1]
    robot.brain.data['locations'] or= {}
    if robot.brain.data['locations'][whereiswho]
      whereisdata = robot.brain.data['locations'][whereiswho]
      ts = whereisdata['ts']
      loc = whereisdata['loc']
      msg.send "Last info about #{whereiswho} at #{ts}: #{loc}"
    else
      msg.send "Sorry, I don't know anything about #{whereiswho}'s whereabouts..."

  robot.respond /([\w .-]+)\'s location is (.*)$/i, (msg) ->
    thereiswho = msg.match[1]
    loc = msg.match[2]
    asof = new Date
    robot.brain.data['locations'] or= {}
    robot.brain.data['locations'][thereiswho] = {'loc': loc, 'ts': asof}
    msg.send "Thanks, noted!"
