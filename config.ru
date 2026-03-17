=begin
Rackは、指定したファイルを独自のRuby DSLとして読み込み、
DSLで指定した様々なミドルウェア、アプリケーションを組み合わせて
Webサーバを立ち上げることができるrackupというコマンドを提供するライブラリ

rackupはRack::Server.start
=end

require 'bundler'
Bundler.require

Dotenv.load
require './app'
run Sinatra::Application
