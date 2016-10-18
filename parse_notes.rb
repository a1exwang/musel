require 'wavefile'
require 'narray'
require 'fftw3'

require_relative 'note'
module Musel
  module AudioParser
    EPSILON = 1e-2

    # midi60 = C4
    # midi69 = A4

    def freq_to_midi(freq)
      12 * Math.log2(freq / 440.0) + 69
    end

    def midi_val_to_name(val, sharp = true)
      h = val / 12 - 1
      note = val % 12
      sharp ?
          [%w'C C# D D# E F F# G G# A A# B'[note], h] :
          [%w'C Db D Eb E F Gb G Ab A Bb B'[note], h]
    end

    DEFAULT_WINDOWING_FUNCTION = lambda do |na, sample_rate, window_duration|
      na
    end

    def make_gauss_windowing_function(var)
      lambda do |na, sample_rate, window_duration|
        sample_count = (sample_rate * window_duration).round
        coef = NArray.float(na.size, 1)
        na.size.times do |i|
          coef[i, 0] = Math.exp(- ((2.0 * i - sample_count) / (sample_count * var)) ** 2 / 2)
        end
        coef * na
      end
    end

    def parse_notes(na, sample_rate, window_duration,
            white_noise, windowing_function = DEFAULT_WINDOWING_FUNCTION)
      fc = FFTW3.fft(windowing_function.call(na, sample_rate, window_duration)) / na.length
      base_freq = 1.0 / window_duration
      sample_count = (sample_rate * window_duration)
      freq_spectrum = Hash.new(0)
      (1...(sample_count / 2)).each do |i|
        freq = i * base_freq
        # As na is real numbers, fc is symmetrical.
        v = (fc[i, 0].magnitude + fc[sample_count - i, 0].magnitude)
        v = 0 if v < white_noise
        midi = freq_to_midi(freq)
        if midi > 28 && midi < 105
          freq_spectrum[midi.round] += v
        end
      end
      freq_spectrum
    end

    def sine_narray(sample_rate, total_time, f1, f2, a1 = 1, a2 = 1)
      f1_dot = f1 / sample_rate.to_f
      f2_dot = f2 / sample_rate.to_f
      sample_count = (sample_rate * total_time).to_i
      na = NArray.float(sample_count, 1)
      sample_count.times do |t|
        v = a1 * Math.sin(2 * Math::PI * t * f1_dot) + a2 * Math.sin(2 * Math::PI * t * f2_dot)
        na[t, 0] = v
      end
      na
    end

    # sample_rate = 8000
    # total_time = 0.1
    # f1 = 220
    # f2 = 440
    # na = sine_narray(sample_rate, total_time, f1, f2)
    # # parse_notes(na, na.size, total_time, 1, 0)

    def parse_file(file_path)
      # First, get sample rate and sample bit width
      reader = WaveFile::Reader.new(file_path)
      format = reader.format
      sample_rate = format.sample_rate
      buffer_size = 44100
      sample_max_value = 1 << format.bits_per_sample
      reader.close

      samples = []
      i = 0
      WaveFile::Reader.new(file_path).each_buffer(buffer_size) do |buffer|
        samples += buffer.samples
        # break if i == 10
        i += 1
      end
      puts "Buffer filled #{samples.size}"
      puts "Max value #{sample_max_value}"
      puts "Samples per second = #{sample_rate}"

      # Calculate window sample count
      bpm = 60
      beats_per_second = bpm / 60.0
      beats_per_window = 1.0 / 8
      window_sample_count = (beats_per_window / beats_per_second * sample_rate).floor
      window_duration = window_sample_count.to_f / sample_rate
      puts "Samples in a window = #{window_sample_count}"
      puts "Window duration = #{window_duration.round(3)}s"

      # Calculate window interval
      sample_interval = window_sample_count / sample_rate.to_f / 2
      puts "Interval between windows = #{sample_interval.round(3)}s"

      freq_arr = []

      t = 0.0
      loop do
        window_start_index = (t * sample_rate).to_i
        break if window_start_index + window_sample_count >= samples.size

        na = NArray.float(window_sample_count, 1)
        samples[window_start_index, window_sample_count].each_with_index do |v, j|
          l, r = v
          na[j, 0] = (l+r)/2
        end
        puts "Parsing notes: #{t.round(2)}s ~ #{(t+sample_interval).round(2)}s"
        pts = parse_notes(na, sample_rate, window_duration, 0.00001, make_gauss_windowing_function(0.25))
        predict_notes = pts.reject { |_, val| val <= 1000 }.sort_by { |_, val| -val }
        pp predict_notes
        freq_arr << pts
        t += sample_interval
      end

      [freq_arr, sample_interval]
    end
  end
end