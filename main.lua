--[[
  Copyright 2014 Google Inc. All Rights Reserved.

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
]]--

require "env"
include "data.lua"
include "utils/strategies.lua"
include "layers/MaskedLoss.lua"
include "layers/Embedding.lua"

function lstm(i, prev_c, prev_h)
  function new_input_sum()
    local i2h            = nn.Linear(params.rnn_size, params.rnn_size)
    local h2h            = nn.Linear(params.rnn_size, params.rnn_size)
    return nn.CAddTable()({i2h(i), h2h(prev_h)})
  end
  local in_gate          = nn.Sigmoid()(new_input_sum())
  local forget_gate      = nn.Sigmoid()(new_input_sum())
  local in_gate2         = nn.Tanh()(new_input_sum())
  local next_c           = nn.CAddTable()({
    nn.CMulTable()({forget_gate, prev_c}),
    nn.CMulTable()({in_gate,     in_gate2})
  })
  local out_gate         = nn.Sigmoid()(new_input_sum())
  local next_h           = nn.CMulTable()({out_gate, nn.Tanh()(next_c)})
  return next_c, next_h
end

function create_network()
  local x                = nn.Identity()() -- 数式
  local y                = nn.Identity()() -- target(答え)
  local prev_s           = nn.Identity()()
  local i                = {[0] = Embedding(symbolsManager.vocab_size,
                                            params.rnn_size)(x)} -- ワンホットを、より高次元に0を補完して埋め込み
  local next_s           = {}
  local splitted         = {prev_s:split(2 * params.layers)}
  for layer_idx = 1, params.layers do
    local prev_c         = splitted[2 * layer_idx - 1]
    local prev_h         = splitted[2 * layer_idx]
    local dropped        = nn.Dropout()(i[layer_idx - 1])       
    local next_c, next_h = lstm(dropped, prev_c, prev_h)
    table.insert(next_s, next_c)
    table.insert(next_s, next_h)
    i[layer_idx] = next_h
  end
  local h2y              = nn.Linear(params.rnn_size, symbolsManager.vocab_size)
  local pred             = nn.LogSoftMax()(h2y(i[params.layers]))
  local err              = MaskedLoss()({pred, y})
  local module           = nn.gModule({x, y, prev_s}, -- prev_sだけを使わずxも使うのは、teacher forcingしたいから
                                      {err, nn.Identity()(next_s)}) -- ネットワーク全体はgModuleクラス
  module:getParameters():uniform(-params.init_weight, params.init_weight) -- ランダムな初期値
  if params.gpuidx > 0 then
    return module:cuda()
  else
    return module
  end
end

function setup()
  print("Creating a RNN LSTM network.")
  local core_network = create_network()
  paramx, paramdx = core_network:getParameters()
  model = {}
  model.s = {}
  model.ds = {}
  model.start_s = {}
  for j = 0, params.seq_length do
    model.s[j] = {}
    for d = 1, 2 * params.layers do
      model.s[j][d] = torch.zeros(params.batch_size, params.rnn_size)
      if params.gpuidx > 0 then
        model.s[j][d] = model.s[j][d]:cuda()
      end

    end
  end
  for d = 1, 2 * params.layers do
    model.start_s[d] = torch.zeros(params.batch_size, params.rnn_size)
    model.ds[d] = torch.zeros(params.batch_size, params.rnn_size)
    if params.gpuidx > 0 then
      model.start_s[d] = model.start_s[d]:cuda()
      model.ds[d] = model.ds[d]:cuda()
    end
  end
  model.core_network = core_network
  model.rnns = cloneManyTimes(core_network, params.seq_length)
  model.norm_dw = 0
  reset_ds()
end

function reset_state(state)
  load_data(state)
  state.pos = 1
  state.acc = 0
  state.count = 0
  state.normal = 0
  if model ~= nil and model.start_s ~= nil then
    for d = 1, 2 * params.layers do
      model.start_s[d]:zero()
    end
  end
end

function reset_ds()
  for d = 1, #model.ds do
    model.ds[d]:zero()
  end
end

function fp(state, paramx_)
  if paramx_ ~= paramx then paramx:copy(paramx_) end
  copy_table(model.s[0], model.start_s)
  if state.pos + params.seq_length > state.data.x:size(1) then
    reset_state(state)
  end
  for i = 1, params.seq_length do
    -- 出力形式は {err=MaskedLoss self.output = {output, acc, normal}, nn.Identity()(next_s=次の入力(c,h))}
    tmp, model.s[i] = unpack(model.rnns[i]:forward({state.data.x[state.pos], -- sを使わず、data.x(真の値)を使っている = teacher forcing
                                                    state.data.y[state.pos + 1],
                                                    model.s[i - 1]}))
    if params.gpuidx > 0 then
      cutorch.synchronize()
    end
    state.pos = state.pos + 1
    state.count = state.count + tmp[2]
    state.normal = state.normal + tmp[3]
  end
  state.acc = state.count / state.normal -- stateを更新している。これにより、showの結果が変わる
  copy_table(model.start_s, model.s[params.seq_length])
end

function bp(state)
  paramdx:zero()
  reset_ds()
  local tmp_val
  if params.gpuidx > 0 then tmp_val = torch.ones(1):cuda() else tmp_val = torch.ones(1) end
  for i = params.seq_length, 1, -1 do
    state.pos = state.pos - 1
    local tmp = model.rnns[i]:backward({state.data.x[state.pos],
                                        state.data.y[state.pos + 1],
                                        model.s[i - 1]},
                                        { tmp_val, model.ds})[3]
    copy_table(model.ds, tmp)
    if params.gpuidx > 0 then
      cutorch.synchronize()
    end
  end
  state.pos = state.pos + params.seq_length
  model.norm_dw = paramdx:norm()
  if model.norm_dw > params.max_grad_norm then
    shrink_factor = params.max_grad_norm / model.norm_dw
    paramdx:mul(shrink_factor)
  end
end

function eval_training(paramx_)
  fp(state_train, paramx_)
  bp(state_train) -- ココ以外でbpは呼ばれない
  return 0, paramdx
end

function run_test(state)
  reset_state(state)
  for i = 1, (state.data.x:size(1) - 1) / params.seq_length do
    fp(state, paramx)
  end
end

function desc_accs(states)
  local accs = ""
  for _, state in pairs(states) do
    accs = string.format('%s, %s acc.=%.2f%%',
      accs, state.name, 100.0 * state.acc)
  end
  return accs
end

function show_predictions(state)
  reset_state(state)
  copy_table(model.s[0], model.start_s)
  local input = {[1] = ""}
  local prediction = {[1] = ""}
  local sample_idx = 1
  local batch_idx = random(params.batch_size)
  for i = 1, state.data.x:size(1) - 1 do
    local tmp = model.rnns[1]:forward({state.data.x[state.pos],
                                              state.data.y[state.pos + 1],
                                              model.s[0]})[2]
    -- 出力形式は {err=MaskedLoss self.output = {output, acc, normal}, nn.Identity()(next_s=次の入力(c,h))}
    -- なので、[2]はnext_sを意味する。                                              
    if params.gpuidx > 0 then
      cutorch.synchronize()
    end
    copy_table(model.s[0], tmp)
    local current_x = state.data.x[state.pos][batch_idx]
    input[sample_idx] = input[sample_idx] ..
                        symbolsManager.idx2symbol[current_x]
    local y = state.data.y[state.pos + 1][batch_idx]
    if y ~= 0 then
      local fnodes = model.rnns[1].forwardnodes
      local pred_vector = fnodes[#fnodes].data.mapindex[1].input[1][batch_idx]
      prediction[sample_idx] = prediction[sample_idx] ..
                               symbolsManager.idx2symbol[argmax(pred_vector)]
    end
    state.pos = state.pos + 1
    local last_x = state.data.x[state.pos - 1][batch_idx]
    if state.pos > 1 and symbolsManager.idx2symbol[last_x] == "." then
      if sample_idx >= 3 * 3 then
        break
      end
      sample_idx = sample_idx + 1
      input[sample_idx] = ""
      prediction[sample_idx] = ""
    end
  end
  io.write(string.format("Some exemplary predictions for the %s dataset\n",
                          state.name))
  for i = 1, #input do
    input[i] = input[i]:gsub("#", "\n\t\t     ")
    input[i] = input[i]:gsub("@", "\n\tTarget:      ")
    io.write(string.format("\tInput:\t     %s", input[i]))
    io.write(string.format("\n\tPrediction:  %s\n", prediction[i]))
    io.write("\t-----------------------------\n")
  end
end

function saveAsFile(filename)
  for i = 1, 1 --[[params.seq_length]] do
    local file = torch.DiskFile("model/" --[[.. i]]--
     .. filename, 'w')
    model.rnns[i]:write(file)
    file:close()
  end
end

function main()

  local cmd = torch.CmdLine()
  cmd:option('-gpuidx', 1, 'Index of GPU on which job should be executed. 0 for CPU')
  cmd:option('-target_length', 6, 'Length of the target expression.')
  cmd:option('-target_nesting', 3, 'Nesting of the target expression.')
  -- Available strategies: baseline, naive, mix, blend.
  cmd:option('-strategy', 'blend', 'Scheduling strategy.')
  cmd:text()
  local opt = cmd:parse(arg)

  params = {batch_size=500, -- 100, GPUのメモリを最大限使いたい
            seq_length=50, -- おそらくこれは、教師データの数式の長さの最大値。rnnの個数でもある。
            layers=2,
            rnn_size=400,
            init_weight=0.08,
            learningRate=0.5,
            max_grad_norm=5,
            target_length=opt.target_length,
            target_nesting=opt.target_nesting,
            target_accuracy=0.95,
            current_length=1,
            current_nesting=1,
            gpuidx = opt.gpuidx}

  init_gpu(opt.gpuidx)
  state_train = {hardness=_G[opt.strategy],
    len=math.max(10001, params.seq_length + 1),
    seed=1,
    kind=0,
    batch_size=params.batch_size,
    name="Training" }
  state_val =   {hardness=current_hardness,
    len=math.max(501, params.seq_length + 1),
    seed=1,
    kind=1,
    batch_size=params.batch_size,
    name="Validation" }

  state_test =  {hardness=target_hardness,
    len=math.max(501, params.seq_length + 1),
    seed=1,
    kind=2,
    batch_size=params.batch_size,
    name="Test"}
  print("Network parameters:")
  print(params)
  local states = {state_train, state_val, state_test }

  for _, state in pairs(states) do
    reset_state(state)
    assert(state.len % params.seq_length == 1)
  end
  setup()
  -- saveAsFile("initial.model")
  local step = 0
  local epoch = 0
  local train_accs = {}
  local total_cases = 0
  local start_time = torch.tic()
  print("Starting training.")
  while true do
    local epoch_size = floor(state_train.data.x:size(1) / params.seq_length)
    -- print('epoch_size = floor(' .. state_train.data.x:size(1) .. ' / ' .. params.seq_length .. ') = ' .. epoch_size)
    step = step + 1
    if step % epoch_size == 0 then
      state_train.seed = state_train.seed + 1
      load_data(state_train)
    end
    optim.adam(eval_training, paramx, {learningRate=params.learningRate}, {}) -- ここで学習(bp)を実行している
    total_cases = total_cases + params.seq_length * params.batch_size
    epoch = ceil(step / epoch_size)
    if step % ceil(epoch_size / 2) == 10 then
      cps = floor(total_cases / torch.toc(start_time))
      run_test(state_val)
      run_test(state_test)
      print('epoch=' .. epoch .. desc_accs(states) ..
        ', current length=' .. params.current_length ..
        ', current nesting=' .. params.current_nesting ..
        ', characters per sec.=' .. cps ..
        ', learning rate=' .. string.format("%.3f", params.learningRate))
      if(epoch > 0 and epoch % 100 == 0) then saveAsFile("epoch" .. epoch .. ".model") end
      if (state_val.acc > params.target_accuracy) --[[or
        (#train_accs >= 5 and
        train_accs[#train_accs - 4] > state_train.acc) ]]--
        then -- これの意味は？早めに、"とびこし"に気づくということ?いくらなんでもたった一回で短気では？
        if not make_harder() then
          params.learningRate = params.learningRate * 0.9 -- ブレーキ効かなすぎてもいやなので、0.8からsqrt(0.81)に緩和
        end
        if params.learningRate < 1e-3 then
          -- ここで最終モデルを保存してみてはどうか?
          saveAsFile("final.model")
          break
        end
        load_data(state_train)
        load_data(state_val)
        train_accs = {}
      end
      train_accs[#train_accs + 1] = state_train.acc
      total_cases = 0
      start_time = torch.tic()
      show_predictions(state_train)
      show_predictions(state_val)
      show_predictions(state_test)
    end
    if step % 33 == 0 then
      collectgarbage()
    end
  end
  print("Training is over.")
end

main()
