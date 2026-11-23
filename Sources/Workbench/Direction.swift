import AVFoundation
import Foundation
import MusicCore
import Security

struct KeyVault {
    static let openAI = KeyVault()
    private let keychain: SecKeychain?

    init(keychain: SecKeychain? = nil) { self.keychain = keychain }

    private var item: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "org.soloforge.community",
         kSecAttrAccount as String: "openai-direction"]
    }

    private var query: [String: Any] {
        var request = item
        if let keychain { request[kSecMatchSearchList as String] = [keychain] }
        return request
    }

    func read(allowInteraction: Bool = true) throws -> String? {
        var request = query
        if !allowInteraction { request[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw DirectionError.vault(status) }
        guard let data = value as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty
        else { throw DirectionError.vault(errSecDecode) }
        return key
    }

    func save(_ input: String) throws {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("sk-"), (12...800).contains(key.count), !key.contains(where: \.isWhitespace) else {
            throw DirectionError.invalidKey
        }
        let changes = [kSecValueData as String: Data(key.utf8)] as CFDictionary
        var status = SecItemUpdate(query as CFDictionary, changes)
        if status == errSecItemNotFound {
            var addition = item
            addition[kSecValueData as String] = Data(key.utf8)
            if let keychain { addition[kSecUseKeychain as String] = keychain }
            status = SecItemAdd(addition as CFDictionary, nil)
            if status == errSecDuplicateItem { status = SecItemUpdate(query as CFDictionary, changes) }
        }
        guard status == errSecSuccess else { throw DirectionError.vault(status) }
        guard try read() == key else { throw DirectionError.unconfirmedSave }
    }

    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DirectionError.vault(status) }
    }
}

enum DirectionError: LocalizedError {
    case noKey, invalidKey, unconfirmedSave, vault(OSStatus), response(Int), malformed, incomplete, timeout, interrupted, serviceFailure
    var errorDescription: String? {
        switch self {
        case .noKey: "Configure a chave nas Preferências → OpenAI."
        case .invalidKey: "Insira uma chave de API OpenAI válida."
        case .unconfirmedSave: "Não foi possível confirmar a gravação. Verifique o acesso ao Chaves e tente salvar novamente."
        case .vault(100002): "O macOS não encontrou um arquivo necessário para acessar o Chaves (100002). Se o SoloForge foi atualizado enquanto estava aberto, encerre e reabra o aplicativo."
        case .vault(errSecUserCanceled): "Você cancelou a autorização de acesso ao Chaves."
        case .vault(errSecInteractionNotAllowed): "Desbloqueie o Chaves de início de sessão e tente novamente."
        case .vault(let code): "Falha ao acessar o Chaves (\(code)). \(SecCopyErrorMessageString(code, nil) as String? ?? "")"
        case .response(401): "A OpenAI recusou a chave. Confira a chave nos Ajustes."
        case .response(403), .response(404): "A conta não tem acesso ao GPT‑6.2 Astra. Confira o projeto da API."
        case .response(429): "A OpenAI atingiu o limite de uso da conta. Confira a cota e tente de novo."
        case .response(408), .response(504), .timeout:
            "A conexão com a OpenAI atingiu o tempo limite. O projeto foi preservado. Você pode tentar novamente."
        case .response(let status): "A OpenAI retornou HTTP \(status). Tente gerar novamente."
        case .interrupted: "A conexão terminou antes da confirmação da OpenAI. As propostas anteriores foram preservadas."
        case .serviceFailure: "A OpenAI interrompeu a geração. As propostas anteriores foram preservadas."
        case .incomplete: "A IA não concluiu o plano de todas as partes. Tente gerar novamente."
        case .malformed: "A resposta musical não passou pela validação. Tente gerar novas opções."
        }
    }
}

enum Director {
    static let model = "gpt-6.2-astra"
    static let modelName = "GPT‑6.2 Astra"
    static let outputLimit = 12_000

    private struct MusicalInput: Encodable {
        struct Section: Encodable {
            let index: Int
            let suggestion: String
            let start: Double
            let end: Double
            let startStep: Int
            let endStep: Int
            let steps: Int
            let firstBarStep: Int
            let precedingPitches: [Int]
            let key: String
            let intensity: Double
            let voice: [[Double]]
            let harmony: [[Int]]
            let accents: [[Int]]
            struct PriorIdea: Encodable { let name: String; let opening: [[Double]] }
            let previousIdeas: [PriorIdea]
        }
        let bpm: Double
        let meter: Int
        let tempoConfidence: Double
        let downbeat: Double
        let level: String
        let mood: String
        let placement: String
        let genre: String
        let maxMidi: Int
        let regenerate: Bool
        let capo: Int
        let playbackTranspose: Int
        let sections: [Section]
    }

    struct Result {
        let plan: ArrangementPlan
        let usage: String
    }

    struct Response: Decodable {
        struct Item: Decodable {
            struct Content: Decodable { let type: String; let text: String? }
            let content: [Content]?
        }
        struct Usage: Decodable { let input_tokens: Int; let output_tokens: Int }
        let status: String?
        let output: [Item]
        let usage: Usage?
    }

    static func plan(project: Project, passage: Passage, level: Level, recording: URL?) async throws -> Result {
        guard let key = try KeyVault.openAI.read() else { throw DirectionError.noKey }
        let map = project.map
        func seconds(_ value: Double) -> Double { (value * 1_000).rounded() / 1_000 }
        let grid = SectionGrid(map: map, passage: passage)
        let regenerate = project.arrangement?.featured != nil
        let analysisPassages = SongStructure.passages(map)
        let file = try recording.map { try AVAudioFile(forReading: $0) }
        // Bound the request while retaining evidence across the full section, including its cadence.
        func distributed<T>(_ items: [T], limit: Int) -> [T] {
            guard items.count > limit else { return items }
            return (0..<limit).map { items[$0 * (items.count - 1) / (limit - 1)] }
        }
        let sections = try analysisPassages.enumerated().map { index, passage -> MusicalInput.Section in
            let chords = map.chords.filter { $0.start < passage.end && $0.end > passage.start }
            let harmony = distributed(chords, limit: 48).map {
                [grid.step(at: max(passage.start, $0.start)), grid.step(at: min(passage.end, $0.end)),
                 Int(($0.confidence * 100).rounded())] + $0.tones
            }
            let accents = try file.map { try RecordingAccents.extract($0, section: passage, map: map, grid: grid) } ?? []
            let first = min(map.waveform.count, Int(passage.start / map.duration * Double(map.waveform.count)))
            let last = min(map.waveform.count, Int(passage.end / map.duration * Double(map.waveform.count)))
            let samples = map.waveform[first..<max(first, last)]
            let intensity = Double(samples.reduce(0, +)) / Double(max(1, samples.count))
            let voice = distributed((map.vocalHints ?? []).filter { $0.start < passage.end && $0.end > passage.start }, limit: 24).map {
                [Double(grid.step(at: max(passage.start, $0.start))), Double(grid.step(at: min(passage.end, $0.end))), seconds($0.confidence)]
            }
            let previous = index == 0 ? project.arrangement?.featured : nil
            let prior = (previous?.alternatives.prefix(5) ?? []).map { phrase in
                MusicalInput.Section.PriorIdea(name: phrase.name,
                                               opening: phrase.events.prefix(7).map { [Double(grid.step(at: $0.time)), Double($0.pitch)] })
            }
            return .init(index: index, suggestion: passage.name, start: seconds(passage.start), end: seconds(passage.end),
                         startStep: grid.step(at: passage.start), endStep: grid.step(at: passage.end), steps: grid.count, firstBarStep: grid.firstBarStep,
                         precedingPitches: project.arrangement?.sections.last(where: { $0.passage.end <= passage.start + 0.001 })?.phrase?.events.suffix(5).map(\.pitch) ?? [],
                         key: map.key(at: passage.start).label, intensity: seconds(intensity), voice: voice,
                         harmony: harmony, accents: accents, previousIdeas: regenerate ? prior : [])
        }
        let input = MusicalInput(bpm: seconds(map.bpm), meter: map.meter, tempoConfidence: seconds(map.tempoConfidence), downbeat: seconds(map.beatOffset),
                                 level: level.rawValue, mood: project.preferences.mood.rawValue,
                                 placement: project.preferences.placement.rawValue, genre: project.preferences.genre?.rawValue ?? "Livre",
                                 maxMidi: 64 + Music.maxFret(level), regenerate: regenerate, capo: project.capo, playbackTranspose: project.transpose, sections: sections)
        let payload = try JSONEncoder().encode(input)
        guard payload.count <= 55_000 else { throw DirectionError.malformed }

        func object(_ properties: [String: Any]) -> [String: Any] {
            ["type": "object", "additionalProperties": false, "required": properties.keys.sorted(), "properties": properties]
        }
        func list(_ items: [String: Any]) -> [String: Any] { ["type": "array", "items": items] }
        let integer = ["type": "integer"]
        let text = ["type": "string"]
        let option = object(["name": text, "intent": text, "score": list(list(integer)),
                             "style": ["type": "string", "enum": SoloIdea.Style.allCases.map(\.rawValue)]])
        let section = object(["index": integer, "name": text, "options": list(option)])
        let schema = object(["amp": ["type": "string", "enum": AmpPreset.allCases.map(\.rawValue)], "sections": list(section)])
        let assignment = """
        Examine o mapa da gravação inteira. Escolha janelas adequadas para solos principais olhando espaço vocal, acordes e curva de intensidade.
        Todos os blocos descrevem a MESMA grade absoluta em semicolcheias, desde o começo da faixa. startStep e endStep delimitam cada bloco.
        Devolva uma seção de índice 0 com um a três solos completos. Escolha apenas as entradas que o mapa justifica.
        Cada solo precisa de ao menos \(SongStructure.minimumSoloPositions) posições distintas (corda e casa). Repita notas importantes. Desenvolva as posições ao longo de toda a frase sem exigir uma altura inédita a cada ataque.
        Desenvolva o motivo em registros diferentes, respeite as pausas e retome as notas marcantes. Evite corridas de escala para completar a contagem.
        Para cada proposta escolha uma passagem contínua, em geral 8 a 16 compassos. Adapte às gravações curtas.
        Apresente um motivo reconhecível, deixe respirar, varie-o sobre as mudanças harmônicas, chegue a um clímax e resolva na volta da banda.
        Prefira 20 a 80 ataques por opção, no máximo 128. Cubra pelo menos 4 compassos ou 55% da gravação se ela for curta.
        Evite lacunas maiores que três compassos dentro do solo.
        Na intenção, explique a escolha da entrada e da resolução com evidências do mapa. Voz ausente no mapa significa evidência desconhecida.
        """
        let rules = """
        Componha solos originais e cantáveis sobre o mapa musical estimado. \(assignment)
        Escreva a frase completa da parte em score. Cada nota é [entrada, duração, altura MIDI inicial, intensidade, gesto, deslocamento]. Deslocamento é opcional, em centésimos de uma semicolcheia, de -40 a +40. Use-o para antecipação, swing ou tercina quando a gravação sugerir. Preserve ataques coincidentes com a banda.
        Entrada e duração são inteiros em semicolcheias na grade indicada. Um tempo tem 4 passos e um compasso tem meter × 4.
        firstBarStep é a posição do primeiro início de compasso na parte. Harmonia e voz seguem a mesma grade. Cada linha de harmony traz [início, fim exclusivo, confiança percentual, fundamental e demais classes de altura do acorde], com dó=0. Fora desses intervalos a harmonia é desconhecida.
        accents contém ataques medidos da mixagem em uma amostra de cada bloco [passo, deslocamento em centésimos de passo, força relativa]. Use o padrão recorrente para colocar a pergunta e a resposta. Uma batida isolada pode vir de qualquer instrumento. Priorize a escuta rítmica do mapa especialmente se tempoConfidence for baixa.
        Escreva cada ataque uma única vez, em ordem, com duração positiva, sem sobreposição e com entrada + duração <= steps.
        Um espaço entre notas é uma pausa. Uma nota pode atravessar a barra de compasso. Planeje a entrada e a saída.
        Escreva as alturas no tom original. A reprodução soma playbackTranspose semitons. Se houver capo,
        planeje notas cuja altura após a transposição caiba entre a corda grave MIDI 40 + capo e a casa física 22.
        Use altura entre 40 e maxMidi, intensidade de 35 a 100.
        Gesto: 0 palhetada, 1 vibrato, 2 ligado à anterior, 3 slide ascendente de um semitom, 4 slide descendente de um semitom,
        5 bend de um semitom, 6 bend de um tom, 7 harmônico natural. O gesto 7 pede a altura QUE SOA: afinação MIDI [64,59,55,50,45,40] acrescida de 12, 19 ou 24. Use-o pontualmente, a partir do intermediário. Iniciante usa 0, Básico usa 0 ou 1. Nos demais níveis marque o gesto que a frase pede.
        Varie articulação, duração e intensidade ao longo do motivo.
        Responda ao motivo conservando algo reconhecível, por exemplo o ritmo, e mudando a chegada de acordo com a troca de acorde.
        Nas partes instrumentais, desenvolva a ideia por mais compassos. Ligue partes vizinhas por uma célula rítmica ou uma nota comum.
        Respeite a função, a dinâmica e o gênero pedidos. Apoie notas longas no acorde que se ouve durante a sustentação e resolva tensões por proximidade.
        Marcas de voz e acordes têm confiança estimada. Priorize sugestões confiáveis. precedingPitches traz o fim da frase anterior quando disponível.
        Escolha o amp. Escreva nome da parte (até 50 caracteres), nome da opção (até 45) e intenção (até 220) em português.
        """
        let (data, envelope) = try await structuredRequest(key: key, payload: payload, rules: rules, schema: schema,
                                                           name: "song_solo_arrangement", limit: outputLimit)
        guard let plan = try? JSONDecoder().decode(ArrangementPlan.self, from: data) else { throw DirectionError.malformed }
        let usage = envelope.usage.map { log in
            let cost = (Double(log.input_tokens) * 8 + Double(log.output_tokens) * 40) / 1_000_000
            return String(format: "%@ · %d entrada + %d saída · US$ %.4f estimados", modelName, log.input_tokens, log.output_tokens, cost)
        } ?? modelName
        return Result(plan: plan, usage: usage)
    }
    struct CapoAdvice: Decodable, Identifiable {
        let fret: Int
        let reason: String
        var id: Int { fret }
    }

    static func adviseCapo(options: [CapoOption], target: String, delta: Int, level: Level) async throws -> [CapoAdvice] {
        guard !options.isEmpty else { throw DirectionError.malformed }
        guard let key = try KeyVault.openAI.read() else { throw DirectionError.noKey }
        struct Input: Encodable { let target: String; let shift: Int; let level: String; let candidates: [CapoOption] }
        let input = Input(target: target, shift: delta, level: level.rawValue, candidates: options)
        let candidate: [String: Any] = ["type": "object", "additionalProperties": false, "required": ["fret", "reason"],
            "properties": ["fret": ["type": "integer", "enum": options.map(\.fret)], "reason": ["type": "string"]]]
        let schema: [String: Any] = ["type": "object", "additionalProperties": false, "required": ["choices"],
            "properties": ["choices": ["type": "array", "items": candidate]]]
        let rules = """
        Escolha até três casas de capotraste dentre as candidatas verificadas. Ordene por utilidade para a música e nível.
        Cada opção soa no tom alvo e preserva as mesmas alturas da melodia. Compare formas de acordes, cordas soltas
        e ressonância. Não atribua mudança de oitava ao capo sozinho. Justifique cada escolha em uma frase em português.
        """
        let (data, _) = try await structuredRequest(key: key, payload: JSONEncoder().encode(input), rules: rules,
                                                    schema: schema, name: "capo_options", limit: 2400)
        return try validatedAdvice(data, allowed: Set(options.map(\.fret)))
    }

    static func validatedAdvice(_ data: Data, allowed: Set<Int>) throws -> [CapoAdvice] {
        struct Result: Decodable { let choices: [CapoAdvice] }
        guard let choices = try? JSONDecoder().decode(Result.self, from: data).choices,
              (1...3).contains(choices.count), Set(choices.map(\.fret)).count == choices.count,
              choices.allSatisfy({ allowed.contains($0.fret) && !$0.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { throw DirectionError.malformed }
        return choices
    }

    private static func structuredRequest(key: String, payload: Data, rules: String, schema: [String: Any],
                                          name: String, limit: Int) async throws -> (Data, Response) {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "store": false, "stream": true, "max_output_tokens": limit,
            "reasoning": ["effort": "medium"], "instructions": rules,
            "input": String(decoding: payload, as: UTF8.self),
            "text": ["format": ["type": "json_schema", "name": name, "strict": true, "schema": schema]]
        ])
        let envelope = try await receive(request)
        guard let raw = envelope.output.compactMap(\.content).flatMap({ $0 }).first(where: { $0.type == "output_text" })?.text
        else { throw DirectionError.malformed }
        return (Data(raw.utf8), envelope)
    }
    // Responses sends each JSON event on a data line. Commit only the terminal, complete response.
    static func receive(_ original: URLRequest, configuration: URLSessionConfiguration = .ephemeral) async throws -> Response {
        var request = original
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 300
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        configuration.timeoutIntervalForResource = 900
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            try await readStream(request, session: session)
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    private static func readStream(_ request: URLRequest, session: URLSession) async throws -> Response {
        struct StreamEvent: Decodable {
            let type: String
            let response: Response?
        }
        do {
            let (stream, response) = try await session.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw DirectionError.response(status) }
            let decoder = JSONDecoder()
            for try await line in stream.lines where line.hasPrefix("data:") {
                try Task.checkCancellation()
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                let event = try decoder.decode(StreamEvent.self, from: Data(payload.utf8))
                switch event.type {
                case "response.completed":
                    guard let result = event.response, result.status == "completed" else { throw DirectionError.malformed }
                    return result
                case "response.incomplete": throw DirectionError.incomplete
                case "response.failed", "error": throw DirectionError.serviceFailure
                default: continue
                }
            }
            try Task.checkCancellation()
            throw DirectionError.interrupted
        } catch let error as URLError {
            try Task.checkCancellation()
            if error.code == .timedOut { throw DirectionError.timeout }
            if error.code == .networkConnectionLost { throw DirectionError.interrupted }
            throw error
        }
    }

}
