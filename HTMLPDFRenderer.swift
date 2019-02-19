//
//  HTMLPDFRenderer.swift
//  HTMLPDFRenderer
//
//  Copyright © 2015 Aleksandar Vacić, Radiant Tap
//	https://github.com/radianttap/HTML2PDFRenderer
//
//  MIT License · http://choosealicense.com/licenses/mit/
//

import UIKit
import WebKit

public protocol HTML2PDFRendererDelegate: class {
	func html2pdfRenderer(_ renderer: HTML2PDFRenderer, didCreatePDFAtFileURL url: URL)
	func html2pdfRenderer(_ renderer: HTML2PDFRenderer, didFailedWithError error: Error)
}

///	Uses UIPrintPageRenderer to create PDF file out of HTML web page loaded in WKWebView.
///
/// See `PaperSize` enum for declaration of supported pages. Extend as needed.
public final class HTML2PDFRenderer
{
	weak var delegate: HTML2PDFRendererDelegate?

	public typealias Callback = (URL?, Error?) -> Void

	//	Internal

	private var webView: WKWebView?
	fileprivate var loader : HTML2PDFRendererLoadStrategy?
}

private extension HTML2PDFRenderer {
	///	UIPrintPageRenderer attributes are read-only, but they can be set using KVC.
	///	Thus modeling those attributes with this enum.
	enum Key: String {
		case paperRect
		case printableRect
	}
}

fileprivate protocol HTML2PDFRendererLoadStrategy
{
	func start(_ webView:WKWebView,completed:@escaping ()->Void)
}

fileprivate class HTML2PDFRendererTimerLoader : HTML2PDFRendererLoadStrategy
{
	var timer : Timer? = nil
	
	func start(_ webView:WKWebView,completed:@escaping ()->Void)
	{
		timer = Timer.every(1.0,
		{ ts in
			if webView.isLoading { return }
			ts.invalidate()
			completed()
		})
	}
}

fileprivate class HTML2PDFRendererJavascriptMessageLoader : NSObject,HTML2PDFRendererLoadStrategy,WKScriptMessageHandler
{
	let configuration : WKWebViewConfiguration
	var completed : (()->Void)? = nil
	
	override init()
	{
		let config = WKWebViewConfiguration()
		configuration = config
		super.init()
		let userContentController = WKUserContentController()
		userContentController.add(self,name:"test")
		config.userContentController = userContentController
	}
	
	func start(_ webView:WKWebView,completed:@escaping ()->Void)
	{
		self.completed = completed
	}
	
	func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage)
	{
		guard message.name == "test" else { return }
		completed?()
	}
}

extension HTML2PDFRenderer
{
	///	Takes the given `htmlURL`, creates hidden `WKWebView`, waits for the web page to load,
	///	then calls the other method below.
	///
	///	Supports both http and file URLs.
	public func render(htmlURL: URL,
				toPDF pdfURL: URL,
				paperSize: PaperSize,
				paperLandscape: Bool = false,
				paperMargins: UIEdgeInsets = .zero,
			    baseUrl:URL?=nil,
				delegate: HTML2PDFRendererDelegate? = nil,
				callback: @escaping Callback = {_, _ in})
	{
		guard let w = UIApplication.shared.keyWindow else { return }
		guard let accessURL = baseUrl ?? FileManager.default.documentsURL else { return }
		
		let bounds : CGRect
		if paperLandscape
		{
			bounds = CGRect(x:0,y:0,width:w.bounds.height,height:w.bounds.width)
		}
		else
		{
			bounds = CGRect(x:0,y:0,width:w.bounds.width,height:w.bounds.height)
		}
		
		let view = UIView(frame:bounds)
		view.alpha = 0
		w.addSubview(view)
		
		loader = HTML2PDFRendererTimerLoader()
//		loader = HTML2PDFRendererJavascriptMessageLoader()
		
		let webView : WKWebView
		if let ls = loader as? HTML2PDFRendererJavascriptMessageLoader
		{
			webView = WKWebView(frame:view.bounds,configuration:ls.configuration)
		}
		else
		{
			webView = WKWebView(frame:view.bounds)
		}
		
		webView.configuration.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
		view.addSubview(webView)
		self.webView = webView
		
		if htmlURL.isFileURL
		{
			webView.loadFileURL(htmlURL, allowingReadAccessTo: accessURL)
		}
		else
		{
			let req = URLRequest(url: htmlURL)
			webView.load(req)
		}
		
		loader?.start(webView)
		{
			self.loader = nil
			
			self.render(webView: webView, toPDF: pdfURL, paperSize: paperSize,paperLandscape:paperLandscape,paperMargins:paperMargins, delegate: delegate)
			{
				[weak self] pdfURL, pdfError in
				guard let self = self else { return }
				
				self.webView?.superview?.removeFromSuperview()
				self.webView = nil
				
				callback(pdfURL, pdfError)
			}
		}
	}

	///	Takes an existing instance of `WKWebView` and prints into paged PDF with specified paper size.
	///
	///	You can supply `delegate` and/or `callback` closure.
	///	Both will be called and given back the file URL where PDF is created or an Error.
	public func render(webView: WKWebView,
				toPDF pdfURL: URL,
				paperSize: PaperSize,
				paperLandscape: Bool = false,
				paperMargins: UIEdgeInsets = .zero,
				delegate: HTML2PDFRendererDelegate? = nil,
				callback: Callback = {_, _ in})
	{
		let fm = FileManager.default
		if !fm.lookupOrCreate(directoryAt: pdfURL.deletingLastPathComponent()) {
			log(level: .warning, "Can't access PDF's parent folder:\n\( pdfURL.deletingLastPathComponent() )")
			return
		}

		let renderer = UIPrintPageRenderer()
		renderer.addPrintFormatter(webView.viewPrintFormatter(), startingAtPageAt: 0)

		let w : CGFloat
		if paperLandscape { w = paperSize.size.height } else { w = paperSize.size.width }
		
		let h : CGFloat
		if paperLandscape { h = paperSize.size.width } else { h = paperSize.size.height }
		
		let paperRect = CGRect(x: 0, y: 0, width: w, height: h)
		renderer.setValue(paperRect, forKey: Key.paperRect.rawValue)

		var printableRect = paperRect
		printableRect.origin.x += paperMargins.left
		printableRect.origin.y += paperMargins.top
		printableRect.size.width -= (paperMargins.left + paperMargins.right)
		printableRect.size.height -= (paperMargins.top + paperMargins.bottom)
		renderer.setValue(printableRect, forKey: Key.printableRect.rawValue)

		let pdfData = renderer.makePDF()

		do {
			try pdfData.write(to: pdfURL, options: .atomicWrite)
			log(level: .info, "Generated PDF file at url:\n\( pdfURL.path )")

			delegate?.html2pdfRenderer(self, didCreatePDFAtFileURL: pdfURL)
			callback(pdfURL, nil)

		} catch let error {
			log(level: .error, "Failed to create PDF:\n\( error )")

			delegate?.html2pdfRenderer(self, didFailedWithError: error)
			callback(nil, error)
			return
		}

	}
}
