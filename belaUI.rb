=begin
    belaUI - web UI for the BELABOX project
    Copyright (C) 2020 BELABOX project

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.
    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
=end

require 'sinatra'
require 'sinatra/json'
require 'sinatra/reloader'
require 'json'
require 'digest'

$setup = JSON.parse(File.read(__dir__ + '/setup.json'))
begin
  $config = JSON.parse(File.read(__dir__ + '/config.json'))
rescue
  $config = {}
end

def save_config
  File.write(__dir__ + '/config.json', $config.to_json)
end

def in_array(array, search)
  array.each_with_index do |el, idx|
    return idx if el == search
  end
  return -1
end

def get_modems
  ignore = "wlan"
  modems = []

  addrs = `ip route show`
  addrs.each_line do |line|
    next if line.match(ignore)
    line = line.split(" ")
    if (srci = in_array(line, 'src')) >= 0
      ip = line[srci+1]
      i = line[2]
      txb = File.read("/sys/class/net/#{i}/statistics/tx_bytes")
      modems.push({:i=>i, :ip=>ip, :txb=>txb})
    end
  end
  modems
end

def get_pipelines()
  pipelines = []
  pipelines += Dir["#{$setup['belacoder_path']}/pipeline/jetson/*"].sort if $setup['hw'] == 'jetson'
  pipelines += Dir["#{$setup['belacoder_path']}/pipeline/generic/*"].sort
  pipelines.map { |pipeline|
    { 'file' => pipeline, 'id' => Digest::SHA1.hexdigest(pipeline) }
  }
end

def search_pipeline(id)
  get_pipelines.each do |pipeline|
    return pipeline if pipeline['id'] == id
  end
  return nil
end

def is_active
  `ps -aux |grep srtla|grep -v grep`.lines.count > 0
end

def set_bitrate(params)
  return nil unless params[:min_br] and params[:max_br]
  min_br = params[:min_br].to_i
  max_br = params[:max_br].to_i
  return nil if min_br < 500 or min_br > 12000
  return nil if max_br < 500 or max_br > 12000
  return nil if min_br > max_br

  File.write("#{$setup['belacoder_path']}/br", "#{min_br*1000}\n#{max_br*1000}\n")

  return [min_br, max_br]
end

get '/' do
  send_file File.expand_path('index.html', settings.public_folder)
end

get '/status' do
  json is_active
end

get '/modems' do
  json get_modems
end

get '/pipelines' do
  json get_pipelines.map { |pipeline|
    if (pipeline['id'] == $config['pipeline'])
      { 'name' => File.basename(pipeline['file']), 'id' => pipeline['id'], 'selected' => true }
    else
      { 'name' => File.basename(pipeline['file']), 'id' => pipeline['id'] }
    end
  }
end

get '/config' do
  json $config
end

post '/stop' do
  system("pkill -f runner.rb")
  system("killall srtla_send")
  system("killall belacoder")
  json system("killall client")
end

post '/start' do
  error 400 unless params[:delay]
  delay = params[:delay].to_i
  error 400 if delay > 2000 or delay < -2000

  error 400 unless params[:pipeline]
  pipeline = search_pipeline(params[:pipeline])
  error 400 unless pipeline

  error 400 unless (bitrate = set_bitrate(params)) != nil

  error 400 unless params[:srtla_addr] and params[:srtla_port]
  srtla_port = params[:srtla_port].to_i
  error 400 unless srtla_port >= 1 and srtla_port <= 0xFFFF

  begin
    srtla_addr = IPSocket.getaddress(params[:srtla_addr])
    $config['srtla_addr'] = params[:srtla_addr]
  rescue
    error 400
  end

  $config['srtla_port'] = srtla_port
  $config['min_br'] = bitrate[0]
  $config['max_br'] = bitrate[1]
  $config['delay'] = delay
  $config['pipeline'] = params[:pipeline]
  save_config()

  json fork { exec("ruby #{__dir__}/runner.rb #{pipeline['file']} #{delay} #{srtla_addr} #{srtla_port}") }
end

post '/bitrate' do
  return json true unless is_active
  error 400 if !set_bitrate(params)
  system("killall -HUP belacoder")
  json true
end

get '/generate_204' do
  redirect "http://#{request.host}/"
end

get '/v1/hello.html' do
  return 'Success'
end
