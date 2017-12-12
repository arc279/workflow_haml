require 'haml'
require 'html2haml'
require 'json'
require 'rexml/document'
require 'open3'

class WorkflowHaml
  FORK_POOL_SIZE = 4
  OPEN3_DEFAULT_OPTS = { unsetenv_others: true, pgroup: true }

  DEFAULT_PLUGINS = {
    echo: ->(el, env, w) {
      w.puts el.text.strip
    },

    sleep: ->(el, env, w) {
      sec = el["sec"].to_f
      sleep(sec)
    },
  }

  def initialize(reader,
                 pool_size: FORK_POOL_SIZE,
                 system_output: STDOUT,
                 command_output: STDOUT,
                 allow_eval: false
                )
    @pool = SizedQueue.new(pool_size)
    @system_output = system_output
    @command_output = command_output
    @allow_eval = allow_eval

    @plugins = DEFAULT_PLUGINS.dup
    haml = Haml::Engine.new(reader)
    @doc = REXML::Document.new(haml.render)
  end

  def add_plugins(kwargs)
    @plugins.merge!(kwargs)
  end

  def error
    @e
  end

  def error?
    ! @e.nil?
  end

  def to_haml
    Html2haml::HTML.new(@doc.to_s).render
  end

  def perform(initial_env: {}, rerun: false)
    @r_sys, @w_sys = IO.pipe
    @r_cmd, @w_cmd = IO.pipe
    @q = Queue.new
    @e = nil
    @resumes = if rerun || @doc.root.attribute("resumes").nil?
                {}
              else
                JSON.parse(@doc.root["resumes"])
              end

    th = Thread.start do
      begin
        # { String => String } の形になってないと駄目
        env2 = initial_env.each.with_object({}) do |(k, v), memo|
          memo[k.to_s] = v.to_s
        end
        __perform(@doc.root, env: env2)
        nil
      rescue => e
        @w_sys.puts e.inspect
        e
      ensure
        @w_sys.close
        @w_cmd.close

        @q.push -> { return false }
      end
    end

    th2 = Thread.start do
      while @q.pop.call do; end
    end

    @system_output.tap do |w|
      w.puts("<system output>")
      @r_sys.each_line do |x|
        w.puts(x)
      end
      w.puts("</system output>")
    end

    @command_output.tap do |w|
      w.puts("<command output>")
      @r_cmd.each_line do |x|
        w.puts(x)
      end
      w.puts("</command output>")
    end

    th2.join
    @e = th.join.value
    @doc.root.add_attribute("resumes", @resumes.to_json)
    unless self.error?
      @doc.root.add_attribute("complete", true)
    end
  end

  private

  def __perform(grp, env: {}, opts: OPEN3_DEFAULT_OPTS.dup)
    if @resumes.key?(grp.xpath)
      env.merge!(@resumes[grp.xpath])
      @w_sys.puts ["skip group", Thread.current, grp.xpath, env].to_json
      return
    end
    @w_sys.puts ["perform group", Thread.current, grp.xpath, env].to_json
    finish_task_grp = -> {
      @resumes[grp.xpath] = env.dup
      return true
    }

    grp.elements.each do |el|
      if @resumes.key?(el.xpath)
        env.merge!(@resumes[el.xpath])
        @w_sys.puts ["skip element", Thread.current, el.xpath, el, env].to_json
        next
      end
      @w_sys.puts ["perform element", Thread.current, el.xpath, el, env].to_json
      finish_task_el = -> {
        @resumes[el.xpath] = env.dup
        return true
      }

      tag = el.name.to_sym
      case tag
      when :group, :root
        __send__(__callee__, el, env: env.dup, opts: opts.dup)
      when :chdir
        opts[:chdir] = el.text.strip
      when :fork
        [].tap do |x|
          el.elements.each do |el2|
            x << Thread.start {
              begin
                @pool.push(:lock)
                __send__(__callee__, el2, env: env.dup, opts: opts.dup)
              ensure
                @pool.pop
              end
            }
          end
        end.each(&:join)
      when :env
        el.attributes.keys.each do |k|
          env[k] = el.attributes[k]
        end
      when :eval
        raise RuntimeError.new("eval not allowed!") unless @allow_eval
        code = el.text
        begin
          $stdout = $stderr = @w_cmd
          eval(code, binding, el.xpath)
        ensure
          $stdout = STDOUT
          $stderr = STDERR
        end
      when :shell
        cmd = el.text
        env2 = env.merge("XPATH" => el.xpath)
        ret = Open3.popen2e(env2, cmd, opts) { |stdin, stdout_and_stderr, thread|
          stdin.close
          @w_cmd.puts stdout_and_stderr.read
          thread.value
        }
        unless ret.exitstatus == 0
          raise RuntimeError.new(ret)
        end
      else
        unless @plugins.key?(tag)
          raise TypeError.new("unknown tag #{tag} '#{el.xpath}'")
        end
        @plugins[tag].call(el, env, @w_sys)
      end

      @q.push finish_task_el
    end

    @q.push finish_task_grp
  end
end


if __FILE__ == $0
  require "pp"
  #require "pry"

  str = if STDIN.isatty
          file = ARGV[0] || 'tasks.haml'
          File.read(file)
        else
          STDIN.read
        end
  w = WorkflowHaml.new(str, allow_eval: true)
  w.add_plugins(
    b: ->(el, env, w) {
      w.puts [el, env, "this is b"].to_json
    },
    c: ->(el, env, w) {
      w.puts [el, env, "this is c"].to_json
    },
  )
  w.perform(initial_env: {
    "this_is_initial": "this is initial",
    "this_is_initial2": 12321,
  })


  STDERR.puts [w.error?, w.error].to_json
  puts w.to_haml
end

