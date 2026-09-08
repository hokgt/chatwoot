# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('custom/wijaya/batteries/core/hooks')

RSpec.describe Wijaya::Batteries::Core::Hooks do
  let(:sentinel) { Object.new }

  describe '.dispatch' do
    it 'returns the default when the feature is not registered' do
      expect(described_class.dispatch(:not_a_feature, :whatever, default: sentinel)).to be(sentinel)
    end

    it 'returns the default when the mapped module cannot be resolved (NameError)' do
      stub_const("#{described_class}::FEATURE_HOOK_MODULES", { ghost: 'No::Such::Module' })

      expect(described_class.dispatch(:ghost, :whatever, default: sentinel)).to be(sentinel)
    end

    it 'returns the default when the resolved module does not respond to the hook' do
      allow(described_class).to receive(:feature_module).and_return(Module.new)

      expect(described_class.dispatch(:x, :missing_hook, default: sentinel)).to be(sentinel)
    end

    it 'returns the hook value on success and forwards keyword args verbatim' do
      mod = Module.new do
        def self.echo(value:)
          value
        end
      end
      allow(described_class).to receive(:feature_module).and_return(mod)

      expect(described_class.dispatch(:x, :echo, default: sentinel, value: 42)).to eq(42)
    end

    it 'fails open to the default when the hook raises StandardError, without propagating' do
      mod = Module.new do
        def self.boom(**)
          raise 'kaboom'
        end
      end
      allow(described_class).to receive(:feature_module).and_return(mod)

      result = nil
      expect { result = described_class.dispatch(:x, :boom, default: sentinel) }.not_to raise_error
      expect(result).to be(sentinel)
    end

    it 'fails open to the default when the hook raises LoadError (broken battery require)' do
      mod = Module.new do
        def self.boom(**)
          raise LoadError, 'cannot load such file -- /secret/battery/path'
        end
      end
      allow(described_class).to receive(:feature_module).and_return(mod)

      result = nil
      expect { result = described_class.dispatch(:x, :boom, default: sentinel) }.not_to raise_error
      expect(result).to be(sentinel)
    end

    it 'fails open to the default when the hook raises SyntaxError/ScriptError (broken battery file)' do
      mod = Module.new do
        def self.boom(**)
          raise SyntaxError, 'unexpected end-of-input'
        end
      end
      allow(described_class).to receive(:feature_module).and_return(mod)

      result = nil
      expect { result = described_class.dispatch(:x, :boom, default: sentinel) }.not_to raise_error
      expect(result).to be(sentinel)
    end

    it 'logs only the feature/hook and error class, never the raw error message' do
      mod = Module.new do
        def self.boom(**)
          raise StandardError, 'PG::Error remote body 0xDEADBEEF secret-token'
        end
      end
      allow(described_class).to receive(:feature_module).and_return(mod)

      logged = []
      allow(Rails.logger).to receive(:error) { |msg| logged << msg }

      described_class.dispatch(:secret_feature, :boom, default: sentinel)

      expect(logged).to include(a_string_including('secret_feature#boom', 'StandardError'))
      expect(logged).not_to include(a_string_including('remote body'))
      expect(logged).not_to include(a_string_including('secret-token'))
    end
  end

  describe '.feature_module' do
    it 'returns the null module when the mapped module cannot be resolved (NameError)' do
      stub_const("#{described_class}::FEATURE_HOOK_MODULES", { ghost: 'No::Such::Module' })

      expect(described_class.feature_module(:ghost)).to be(described_class::NULL_MODULE)
    end

    it 'returns the null module when resolution raises LoadError/ScriptError (broken battery file)' do
      # +String gives an unfrozen literal so its singleton :constantize can be stubbed
      # (this file is frozen_string_literal). The same object is returned from the map,
      # so feature_module calls the stubbed constantize which raises LoadError < ScriptError.
      broken_name = +'Broken::Battery'
      stub_const("#{described_class}::FEATURE_HOOK_MODULES", { broken: broken_name })
      allow(broken_name).to receive(:constantize).and_raise(LoadError.new('cannot load such file -- /secret/path'))

      expect(described_class.feature_module(:broken)).to be(described_class::NULL_MODULE)
    end

    it 'dispatch fails open to the default when module resolution raises ScriptError' do
      broken_name = +'Broken::Battery'
      stub_const("#{described_class}::FEATURE_HOOK_MODULES", { broken: broken_name })
      allow(broken_name).to receive(:constantize).and_raise(NotImplementedError.new('broken'))

      expect(described_class.dispatch(:broken, :whatever, default: sentinel)).to be(sentinel)
    end
  end
end
