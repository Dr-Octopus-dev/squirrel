//
//  SquirrelPanel.swift
//  Squirrel
//
//  Created by Leo Liu on 5/10/24.
//

import AppKit

final class SquirrelPanel: NSPanel {
  private let view: SquirrelView
  private let back: NSVisualEffectView
  var inputController: SquirrelInputController?

  var position: NSRect
  private var screenRect: NSRect = .zero
  private var maxHeight: CGFloat = 0

  private var statusMessage: String = ""
  private var statusTimer: Timer?

  private var preedit: String = ""
  private var selRange: NSRange = .empty
  private var caretPos: Int = 0
  private var candidates: [String] = .init()
  private var comments: [String] = .init()
  private var labels: [String] = .init()
  private var index: Int = 0
  private var cursorIndex: Int = 0
  private var scrollDirection: CGVector = .zero
  private var scrollTime: Date = .distantPast
  private var page: Int = 0
  private var lastPage: Bool = true
  private var pagingUp: Bool?
  
  //候选项富文本
  var lines:[NSMutableAttributedString] = []
  //实测改成NSAttributedString也不能解决新的1-0-0问题
//  var lines:[NSAttributedString] = []

  init(position: NSRect) {
    self.position = position
    self.view = SquirrelView(frame: position)
    self.back = NSVisualEffectView()
    super.init(contentRect: position, styleMask: .nonactivatingPanel, backing: .buffered, defer: true)
    self.level = .init(Int(CGShieldingWindowLevel()))
    self.hasShadow = true
    self.isOpaque = false
    self.backgroundColor = .clear
    back.blendingMode = .behindWindow
    back.material = .hudWindow
    back.state = .active
    back.wantsLayer = true
    back.layer?.mask = view.shape
    let contentView = NSView()
    contentView.addSubview(back)
    contentView.addSubview(view)
    contentView.addSubview(view.textView)
    //显示原本TextView的边界方便调试
//    view.textView.wantsLayer = true // 确保textView使用layer进行绘制
//    view.textView.layer?.borderWidth = 2.0 // 设置边框宽度
//    view.textView.layer?.borderColor = NSColor.orange.cgColor // 设置边框颜色为橙色
    view.textView.isHidden = true

    self.contentView = contentView
    //存储lines的容器
    contentView.addSubview(view.textStack)
//    view.textStack.alignment =  .firstBaseline
//    view.textStack.alignment =  .leading //竖排的时候用这个向左对齐
//    view.textStack.orientation = .horizontal //水平
//    view.textStack.orientation = .vertical //垂直
//    view.textStack.distribution = .gravityAreas
//    view.textStack.distribution = .fillProportionally //根据每个候选项占比分配剩余空间
    view.textStack.spacing = 0 // 设置子视图之间的间隔
    view.textStack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      view.textStack.leadingAnchor.constraint(equalTo: self.contentView!.leadingAnchor),
      view.textStack.trailingAnchor.constraint(equalTo: self.contentView!.trailingAnchor),
      view.textStack.topAnchor.constraint(equalTo: self.contentView!.topAnchor),
      view.textStack.bottomAnchor.constraint(equalTo: self.contentView!.bottomAnchor),
    ])
  }

  var linear: Bool {
    view.currentTheme.linear
  }
  var vertical: Bool {
    view.currentTheme.vertical
  }
  var inlinePreedit: Bool {
    view.currentTheme.inlinePreedit
  }
  var inlineCandidate: Bool {
    view.currentTheme.inlineCandidate
  }

  // swiftlint:disable:next cyclomatic_complexity
  override func sendEvent(_ event: NSEvent) {
    switch event.type {
    case .leftMouseDown:
      let (index, _, pagingUp) =  view.click(at: mousePosition())
      if let pagingUp {
        self.pagingUp = pagingUp
      } else {
        self.pagingUp = nil
      }
      if let index, index >= 0 && index < candidates.count {
        self.index = index
      }
    case .leftMouseUp:
      let (index, preeditIndex, pagingUp) = view.click(at: mousePosition())

      if let pagingUp, pagingUp == self.pagingUp {
        _ = inputController?.page(up: pagingUp)
      } else {
        self.pagingUp = nil
      }
      if let preeditIndex, preeditIndex >= 0 && preeditIndex < preedit.utf16.count {
        if preeditIndex < caretPos {
          _ = inputController?.moveCaret(forward: true)
        } else if preeditIndex > caretPos {
          _ = inputController?.moveCaret(forward: false)
        }
      }
      if let index, index == self.index && index >= 0 && index < candidates.count {
        _ = inputController?.selectCandidate(index)
      }
    case .mouseEntered:
      acceptsMouseMovedEvents = true
    case .mouseExited:
      acceptsMouseMovedEvents = false
      if cursorIndex != index {
        update(preedit: preedit, selRange: selRange, caretPos: caretPos, candidates: candidates, comments: comments, labels: labels, highlighted: index, page: page, lastPage: lastPage, update: false)
      }
      pagingUp = nil
    case .mouseMoved:
      let (index, _, _) = view.click(at: mousePosition())
      if let index = index, cursorIndex != index && index >= 0 && index < candidates.count {
        update(preedit: preedit, selRange: selRange, caretPos: caretPos, candidates: candidates, comments: comments, labels: labels, highlighted: index, page: page, lastPage: lastPage, update: false)
      }
    case .scrollWheel:
      if event.phase == .began {
        scrollDirection = .zero
        // Scrollboard span
      } else if event.phase == .ended || (event.phase == .init(rawValue: 0) && event.momentumPhase != .init(rawValue: 0)) {
        if abs(scrollDirection.dx) > abs(scrollDirection.dy) && abs(scrollDirection.dx) > 10 {
          _ = inputController?.page(up: (scrollDirection.dx < 0) == vertical)
        } else if abs(scrollDirection.dx) < abs(scrollDirection.dy) && abs(scrollDirection.dy) > 10 {
          _ = inputController?.page(up: scrollDirection.dy > 0)
        }
        scrollDirection = .zero
        // Mouse scroll wheel
      } else if event.phase == .init(rawValue: 0) && event.momentumPhase == .init(rawValue: 0) {
        if scrollTime.timeIntervalSinceNow < -1 {
          scrollDirection = .zero
        }
        scrollTime = .now
        if (scrollDirection.dy >= 0 && event.scrollingDeltaY > 0) || (scrollDirection.dy <= 0 && event.scrollingDeltaY < 0) {
          scrollDirection.dy += event.scrollingDeltaY
        } else {
          scrollDirection = .zero
        }
        if abs(scrollDirection.dy) > 10 {
          _ = inputController?.page(up: scrollDirection.dy > 0)
          scrollDirection = .zero
        }
      } else {
        scrollDirection.dx += event.scrollingDeltaX
        scrollDirection.dy += event.scrollingDeltaY
      }
    default:
      break
    }
    super.sendEvent(event)
  }

  func hide() {
    statusTimer?.invalidate()
    statusTimer = nil
    orderOut(nil)
    maxHeight = 0
  }

  // Main function to add attributes to text output from librime
  // swiftlint:disable:next cyclomatic_complexity function_parameter_count
  func update(preedit: String, selRange: NSRange, caretPos: Int, candidates: [String], 
              comments: [String], labels: [String], highlighted index: Int, page: Int,
              lastPage: Bool, update: Bool) {
//    print("**** update() ****")
//    print("preedit:\(preedit)")
//    print("selRange:\(selRange)")
//    print("caretPos:\(caretPos)")
//    print("candidates:\(candidates)")
//    print("comments:\(comments)")
//    print("labels:\(labels)")
//    print("index:\(index)")
//    print("page:\(page)")
//    print("lastPage:\(lastPage)")
//    print("update:\(update)")
    
    if update {
      self.preedit = preedit
      self.selRange = selRange
      self.caretPos = caretPos //光标位置
      self.candidates = candidates //候选项
      self.comments = comments //评论
      self.labels = labels
      self.index = index //当前高亮（从0开始）
      self.page = page //当前页
      self.lastPage = lastPage //当前是否最后一页
    }
    cursorIndex = index

    if !candidates.isEmpty || !preedit.isEmpty {
      statusMessage = ""
      statusTimer?.invalidate()
      statusTimer = nil
    } else {
      if !statusMessage.isEmpty {
//        print("statusMessage非空")
        show(status: statusMessage)
        statusMessage = ""
      } else if statusTimer == nil {
        hide()
      }
//      print("update()结束")
      return
    }

//    print("到这里了")
    let theme = view.currentTheme
    currentScreen()

    let text = NSMutableAttributedString()
    let preeditRange: NSRange
    let highlightedPreeditRange: NSRange

    // preedit
    if !preedit.isEmpty {
      preeditRange = NSRange(location: 0, length: preedit.utf16.count)
      highlightedPreeditRange = selRange

      let line = NSMutableAttributedString(string: preedit)
      line.addAttributes(theme.preeditAttrs, range: preeditRange)
      line.addAttributes(theme.preeditHighlightedAttrs, range: selRange)
      text.append(line)

      text.addAttribute(.paragraphStyle, value: theme.preeditParagraphStyle, range: NSRange(location: 0, length: text.length))
      if !candidates.isEmpty {
        text.append(NSAttributedString(string: "\n", attributes: theme.preeditAttrs))
      }
    } else {
      preeditRange = .empty
      highlightedPreeditRange = .empty
    }

    // candidates
    var candidateRanges = [NSRange]()
    //存储候选项line
    lines = []
    for i in 0..<candidates.count {
//      print("**** 开始打印candidates ****")
//      print("theme.highlightedAttrs的类型是：\(type(of: theme.highlightedAttrs))")
//      print("theme.highlightedAttrs:\(theme.highlightedAttrs) \n")
//      print("theme.attrs:\(theme.attrs) \n")
//      print("theme.labelHighlightedAttrs:\(theme.labelHighlightedAttrs) \n")
//      print("theme.labelAttrs:\(theme.labelAttrs) \n")
//      print("theme.commentHighlightedAttrs:\(theme.commentHighlightedAttrs)\n")
//      print("theme.commentAttrs:\(theme.commentAttrs)\n")

      //如果当前选项是被高亮的，那就用高亮主题
      let attrs = i == index ? theme.highlightedAttrs : theme.attrs
      let labelAttrs = i == index ? theme.labelHighlightedAttrs : theme.labelAttrs
      let commentAttrs = i == index ? theme.commentHighlightedAttrs : theme.commentAttrs

//      print("theme.candidateFormat:\(theme.candidateFormat)\n")
      let label = if theme.candidateFormat.contains(/\[label\]/) {
        if labels.count > 1 && i < labels.count {
          labels[i]
        } else if labels.count == 1 && i < labels.first!.count {
          // custom: A. B. C...
          String(labels.first![labels.first!.index(labels.first!.startIndex, offsetBy: i)])
        } else {
          // default: 1. 2. 3...
          "\(i+1)"
        }
      } else {
        ""
      }

      let candidate = candidates[i].precomposedStringWithCanonicalMapping
      let comment = comments[i].precomposedStringWithCanonicalMapping

      //一个line就是一个候选项，内部默认由序号、候选项内容、评论组成，具体看attributes
      let line = NSMutableAttributedString(string: theme.candidateFormat, attributes: labelAttrs)
//      print("labelAttrs:\(labelAttrs)")
      
      for range in line.string.ranges(of: /\[candidate\]/) {
        let convertedRange = convert(range: range, in: line.string)
        line.addAttributes(attrs, range: convertedRange)
        if candidate.count <= 5 {
          line.addAttribute(.noBreak, value: true, range: NSRange(location: convertedRange.location+1, length: convertedRange.length-1))
        }
      }
      for range in line.string.ranges(of: /\[comment\]/) {
        line.addAttributes(commentAttrs, range: convert(range: range, in: line.string))
      }
      line.mutableString.replaceOccurrences(of: "[label]", with: label, range: NSRange(location: 0, length: line.length))
      let labeledLine = line.copy() as! NSAttributedString
      line.mutableString.replaceOccurrences(of: "[candidate]", with: candidate, range: NSRange(location: 0, length: line.length))
      line.mutableString.replaceOccurrences(of: "[comment]", with: comment, range: NSRange(location: 0, length: line.length))

      if line.length <= 10 {
        line.addAttribute(.noBreak, value: true, range: NSRange(location: 1, length: line.length-1))
      }

      //纵向模式把空格换成换行符
      let lineSeparator = NSAttributedString(string: linear ? "  " : "\n", attributes: attrs)
//      print("attrs:{\(attrs)}")
//      print("lineSeparator:{\(lineSeparator)}")
      if i > 0 {
        text.append(lineSeparator)
      }
      let str = lineSeparator.mutableCopy() as! NSMutableAttributedString
      if vertical {
        str.addAttribute(.verticalGlyphForm, value: 1, range: NSRange(location: 0, length: str.length))
      }
      view.separatorWidth = str.boundingRect(with: .zero).width

//      print("theme.firstParagraphStyle:\(theme.firstParagraphStyle)")
//      print("theme.paragraphStyle:\(theme.paragraphStyle)")
      let paragraphStyleCandidate = (i == 0 ? theme.firstParagraphStyle : theme.paragraphStyle).mutableCopy() as! NSMutableParagraphStyle
      if linear {
//        print("theme.linespace:\(theme.linespace)")
        paragraphStyleCandidate.paragraphSpacingBefore -= theme.linespace
        paragraphStyleCandidate.lineSpacing = theme.linespace
      }
      if !linear, let labelEnd = labeledLine.string.firstMatch(of: /\[(candidate|comment)\]/)?.range.lowerBound {
        let labelString = labeledLine.attributedSubstring(from: NSRange(location: 0, length: labelEnd.utf16Offset(in: labeledLine.string)))
        let labelWidth = labelString.boundingRect(with: .zero, options: [.usesLineFragmentOrigin]).width
        paragraphStyleCandidate.headIndent = labelWidth
      }
      line.addAttribute(.paragraphStyle, value: paragraphStyleCandidate, range: NSRange(location: 0, length: line.length))

      candidateRanges.append(NSRange(location: text.length, length: line.length))
      text.append(line)
      lines.append(line)

//      //添加空格
//      var separatedLine = NSMutableAttributedString()
//      if i == 0 {
//        let separator = NSAttributedString(string: "   ")
//        separatedLine.append(separator)
//      }
//      if i > 0 {
//        let separator = NSAttributedString(string: "  ", attributes: attrs)
//        separatedLine.append(separator)
//      }
//      separatedLine.append(line)
//      lines.append(separatedLine)
    }
    
    /// 在每个候选项前面加三个默认格式的空格，后面加一个，竟意外地跟原版视图对齐了，原因未知，尝试过上面attrs格式的空格，但是反而跟原版对不齐，
    /// 悬而未决，暂时搁置
    for i in 0..<lines.count {
      lines[i].insert(NSAttributedString(string: "   "), at: 0)
      lines[i].append(NSAttributedString(string: " "))
//      print("****")
//      print(lines[i])
//      print("****")
    }
    // text done!
    //以下三行绘制富文本
    view.textView.textContentStorage?.attributedString = text
    view.textView.setLayoutOrientation(vertical ? .vertical : .horizontal)
    view.drawView(candidateRanges: candidateRanges, hilightedIndex: index, preeditRange: preeditRange, highlightedPreeditRange: highlightedPreeditRange, canPageUp: page > 0, canPageDown: !lastPage)

    if linear && !vertical {//拆分候选的动画暂时仅支持横版横排的情况
      showWithSeparatedCandidates()
    }else{
      show()
    }
    ///流程解读：
    ///按下键发送给librime后，librime会经过一段时间的计算，然后发回，
    ///在收到librime的候选项数组后，SqruirrelPanel用update方法处理成line的集合，拼接成text，然后放进SqruirrelView.textView的textContentStorage里，
    ///然后调用show方法，show方法会先计算一个合适的候选框位置，然后给SqruirrelView进行一些配置（感觉这些应该放在draw里），然后用orderFront(nil)
    ///把SqruirrelView呼到前台，SqruirrelView到前台后会自动调draw方法
    ///
    ///思路1：在View里添加一个属性var lines:[NSMutableAttributedString] = []，用来接收lines，然后在draw方法里把lines处理成一个个GCLayer
    ///难点：如果计算初始化的每个候选项的位置？
    ///思路2：新建一个NSView类，就叫Line或者其他名字，用来表示每个候选项
    ///
    ///2024年12月18日更新：
    ///现在做出来了，思路是重写NSTextField类，让其frame在didSet的时候自动添加动画，然后把每个NSTextField作为候选项放进
    ///NSStackView里，这样好处是全自动的，只需要手动改变候选项的文本，改变后候选项长度变了，stack会自动排列，排列的时候
    ///改变了位置会自动添加动画
  }

  func updateStatus(long longMessage: String, short shortMessage: String) {
    let theme = view.currentTheme
    switch theme.statusMessageType {
    case .mix:
      statusMessage = shortMessage.isEmpty ? longMessage : shortMessage
    case .long:
      statusMessage = longMessage
    case .short:
      if !shortMessage.isEmpty {
        statusMessage = shortMessage
      } else if let initial = longMessage.first {
        statusMessage = String(initial)
      } else {
        statusMessage = ""
      }
    }
  }

  func load(config: SquirrelConfig, forDarkMode isDark: Bool) {
    if isDark {
      view.darkTheme = SquirrelTheme()
      view.darkTheme.load(config: config, dark: true)
    } else {
      view.lightTheme = SquirrelTheme()
      view.lightTheme.load(config: config, dark: isDark)
    }
  }
}

private extension SquirrelPanel {
  func mousePosition() -> NSPoint {
    var point = NSEvent.mouseLocation
    point = self.convertPoint(fromScreen: point)
    return view.convert(point, from: nil)
  }

  func currentScreen() {
    if let screen = NSScreen.main {
      screenRect = screen.frame
    }
    for screen in NSScreen.screens where screen.frame.contains(position.origin) {
      screenRect = screen.frame
      break
    }
  }

  func maxTextWidth() -> CGFloat {
    let theme = view.currentTheme
    let font: NSFont = theme.font
    let fontScale = font.pointSize / 12
    let textWidthRatio = min(1, 1 / (vertical ? 4 : 3) + fontScale / 12)
    let maxWidth = if vertical {
      screenRect.height * textWidthRatio - theme.edgeInset.height * 2
    } else {
      screenRect.width * textWidthRatio - theme.edgeInset.width * 2
    }
    return maxWidth
  }

  // Get the window size, the windows will be the dirtyRect in
  // SquirrelView.drawRect
  // swiftlint:disable:next cyclomatic_complexity
  func show() {
//    print("**** SquirrelPanel.show() ****")
    self.currentScreen()
    let theme = self.view.currentTheme
    if !self.view.darkTheme.available {
      self.appearance = NSAppearance(named: .aqua)
    }
    
    // Break line if the text is too long, based on screen size.
    let textWidth = self.maxTextWidth()
    let maxTextHeight = self.vertical ? self.screenRect.width - theme.edgeInset.width * 2 : self.screenRect.height - theme.edgeInset.height * 2
    self.view.textContainer.size = NSSize(width: textWidth, height: maxTextHeight)
    
    //从这里开始是为了计算一个对屏幕合适的候选框坐标范围，得到一个panelRect
    var panelRect = NSRect.zero
    // in vertical mode, the width and height are interchanged
    var contentRect = self.view.contentRect
    if theme.memorizeSize && (self.vertical && self.position.midY / self.screenRect.height < 0.5) ||
        (self.vertical && self.position.minX + max(contentRect.width, self.maxHeight) + theme.edgeInset.width * 2 > self.screenRect.maxX) {
      if contentRect.width >= self.maxHeight {
        self.maxHeight = contentRect.width
      } else {
        contentRect.size.width = self.maxHeight
        self.view.textContainer.size = NSSize(width: self.maxHeight, height: maxTextHeight)
      }
    }
    if self.vertical {
      panelRect.size = NSSize(width: min(0.95 * self.screenRect.width, contentRect.height + theme.edgeInset.height * 2),
                              height: min(0.95 * self.screenRect.height, contentRect.width + theme.edgeInset.width * 2) + theme.pagingOffset)
      
      // To avoid jumping up and down while typing, use the lower screen when
      // typing on upper, and vice versa
      if self.position.midY / self.screenRect.height >= 0.5 {
        panelRect.origin.y = self.position.minY - SquirrelTheme.offsetHeight - panelRect.height + theme.pagingOffset
      } else {
        panelRect.origin.y = self.position.maxY + SquirrelTheme.offsetHeight
      }
      // Make the first candidate fixed at the left of cursor
      panelRect.origin.x = self.position.minX - panelRect.width - SquirrelTheme.offsetHeight
      if self.view.preeditRange.length > 0, let preeditTextRange = self.view.convert(range: self.view.preeditRange) {
        let preeditRect = self.view.contentRect(range: preeditTextRange)
        panelRect.origin.x += preeditRect.height + theme.edgeInset.width
      }
    } else {
      panelRect.size = NSSize(width: min(0.95 * self.screenRect.width, contentRect.width + theme.edgeInset.width * 2),
                              height: min(0.95 * self.screenRect.height, contentRect.height + theme.edgeInset.height * 2))
      panelRect.size.width += theme.pagingOffset
      panelRect.origin = NSPoint(x: self.position.minX - theme.pagingOffset, y: self.position.minY - SquirrelTheme.offsetHeight - panelRect.height)
    }
    if panelRect.maxX > self.screenRect.maxX {
      panelRect.origin.x = self.screenRect.maxX - panelRect.width
    }
    if panelRect.minX < self.screenRect.minX {
      panelRect.origin.x = self.screenRect.minX
    }
    if panelRect.minY < self.screenRect.minY {
      if self.vertical {
        panelRect.origin.y = self.screenRect.minY
      } else {
        panelRect.origin.y = self.position.maxY + SquirrelTheme.offsetHeight
      }
    }
    if panelRect.maxY > self.screenRect.maxY {
      panelRect.origin.y = self.screenRect.maxY - panelRect.height
    }
    if panelRect.minY < self.screenRect.minY {
      panelRect.origin.y = self.screenRect.minY
    }
//    panelRect.size.width += 50
    /// panelRect为候选视图的坐标、范围，这里赋予panel
    self.setFrame(panelRect, display: true)
    //      print(panelRect)
    //这里开始要配置NSView的属性了
    ///这里如果vertical为真，contentView（NSPanel的一个View）会旋转90度
    // rotate the view, the core in vertical mode!
    if self.vertical {
      self.contentView!.boundsRotation = -90
      self.contentView!.setBoundsOrigin(NSPoint(x: 0, y: panelRect.width))
    } else {
      self.contentView!.boundsRotation = 0
      self.contentView!.setBoundsOrigin(.zero)
    }
    self.view.textView.boundsRotation = 0
    view.textView.setBoundsOrigin(.zero)
    
    view.frame = contentView!.bounds
    view.textView.frame = contentView!.bounds
    view.textView.frame.size.width -= theme.pagingOffset
    view.textView.frame.origin.x += theme.pagingOffset
    view.textView.textContainerInset = theme.edgeInset
    
    if theme.translucency {
      back.frame = contentView!.bounds
      back.frame.size.width += theme.pagingOffset
      back.appearance = NSApp.effectiveAppearance
      back.isHidden = false
    } else {
      back.isHidden = true
    }
    alphaValue = theme.alpha
    invalidateShadow()
    ///  这个方法是NSWindow的（NSWindow的子类NSPanel也有），这个方法会把NSView（所有的，macOS似乎就是
    ///  只能把一个App的所有窗口带到前台，不能单独），被带到前台的NSView会自动调自己的draw()方法
    //      orderFront(nil)
    // voila!
  }

  func show(status message: String) {
//    print("**** show(status message: String) ****")
    let theme = view.currentTheme
    let text = NSMutableAttributedString(string: message, attributes: theme.attrs)
    text.addAttribute(.paragraphStyle, value: theme.paragraphStyle, range: NSRange(location: 0, length: text.length))
    view.textContentStorage.attributedString = text
    view.textView.setLayoutOrientation(vertical ? .vertical : .horizontal)
    view.drawView(candidateRanges: [NSRange(location: 0, length: text.length)], hilightedIndex: -1,
                  preeditRange: .empty, highlightedPreeditRange: .empty, canPageUp: false, canPageDown: false)
    show()

    statusTimer?.invalidate()
    statusTimer = Timer.scheduledTimer(withTimeInterval: SquirrelTheme.showStatusDuration, repeats: false) { _ in
      self.hide()
    }
  }
  
  func showWithSeparatedCandidates(){
    self.currentScreen()//获取显示器信息
    let theme = self.view.currentTheme
    //下面开始计算锚点
    var panelRect = NSRect.zero
    panelRect.origin = NSPoint(x: self.position.minX - theme.pagingOffset, y: self.position.minY - SquirrelTheme.offsetHeight - panelRect.height)
    self.setFrame(panelRect, display: true)
    
    //下面开始添加候选项视图
    let oldNum = view.textStack.subviews.count
    let newNum = lines.count
//    print("oldNum:\(oldNum),newNum:\(newNum)")
    
    if oldNum < newNum{
      //初始化差额的候选项视图
      for i in oldNum..<newNum{
        let animateNSTextView = AnimateNSTextView()
        //在这里把animateNSTextView做成跟上面line一样的效果
        animateNSTextView.wantsLayer = true
//        animateNSTextView.font = NSFont.systemFont(ofSize: 20)
        animateNSTextView.isEditable = false //导致1-0-0问题的罪魁祸首
//        animateNSTextView.layer?.borderWidth = 3.0
//        animateNSTextView.layer?.borderColor = NSColor.blue.cgColor//开发阶段，用边框定位
        animateNSTextView.isBordered = false //这项不设的话背景还是不透明(仅限NSTextFeild)
        animateNSTextView.backgroundColor = NSColor.clear //设置透明方便看后面的鼠须管原字段(仅限NSTextFeild)
        view.textStack.addArrangedSubview(animateNSTextView)
        print("少啦，增加第\(i)个")
      }
    }else if oldNum == newNum{
      
    }else if oldNum > newNum{
      for _ in newNum..<oldNum{
        let viewToRemove = view.textStack.arrangedSubviews[newNum]
        view.textStack.removeArrangedSubview(viewToRemove)
        viewToRemove.removeFromSuperview()
        print("超标啦,删除第\(newNum)个")
      }
    }
    //更新文字
    for (i,view) in view.textStack.arrangedSubviews.enumerated(){
      if let animateNSTextView = view as? AnimateNSTextView {
        //更新动画参数（这样写其实有点屎山，但是为了防止重新部署后不同步，所以每次update都更新得了）
        animateNSTextView.animationOn = theme.candidateAnimationOn
        animateNSTextView.animationTypeStr = theme.candidateAnimationType
        animateNSTextView.animationDuration = theme.candidateAnimationDuration
        animateNSTextView.animationInterruptType = theme.candidateAnimationInterruptType
        animateNSTextView.page = page
        animateNSTextView.i = i
        //        animateNSTextView.textContentStorage?.attributedString = lines[i] //如果是NSTextView用这个
        animateNSTextView.attributedStringValue = lines[i] //更新视图字符串
//        print("更新前lines[i]:[\(lines[i].string)]")
//        print("更新后的a.a.string：[\(animateNSTextView.attributedStringValue.string)]")
//        print("padding：",self.view.textContainer.lineFragmentPadding)
//        print("右边距：",animateNSTextView.layer?.layoutManager.rightAnchor)
      }
    }
    //请求前台显示，并且不强求成为活动窗口
    orderFrontRegardless()
  }

  func convert(range: Range<String.Index>, in string: String) -> NSRange {
    let startPos = range.lowerBound.utf16Offset(in: string)
    let endPos = range.upperBound.utf16Offset(in: string)
    return NSRange(location: startPos, length: endPos - startPos)
  }
}
