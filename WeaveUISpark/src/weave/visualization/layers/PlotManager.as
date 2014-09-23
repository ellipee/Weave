/*
    Weave (Web-based Analysis and Visualization Environment)
    Copyright (C) 2008-2011 University of Massachusetts Lowell

    This file is a part of Weave.

    Weave is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License, Version 3,
    as published by the Free Software Foundation.

    Weave is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with Weave.  If not, see <http://www.gnu.org/licenses/>.
*/

package weave.visualization.layers
{
	import flash.display.Bitmap;
	import flash.display.BitmapData;
	import flash.display.DisplayObject;
	import flash.display.Graphics;
	import flash.display.PixelSnapping;
	import flash.display.Shape;
	import flash.events.Event;
	import flash.filters.GlowFilter;
	import flash.geom.ColorTransform;
	import flash.geom.Matrix;
	import flash.geom.Point;
	import flash.geom.Rectangle;
	import flash.utils.Dictionary;
	import flash.utils.getTimer;
	
	import weave.Weave;
	import weave.api.core.ICallbackCollection;
	import weave.api.core.ILinkableObject;
	import weave.api.data.IKeySet;
	import weave.api.data.IQualifiedKey;
	import weave.api.data.ISimpleGeometry;
	import weave.api.getCallbackCollection;
	import weave.api.linkableObjectIsBusy;
	import weave.api.newDisposableChild;
	import weave.api.newLinkableChild;
	import weave.api.primitives.IBounds2D;
	import weave.api.registerDisposableChild;
	import weave.api.registerLinkableChild;
	import weave.api.reportError;
	import weave.api.setSessionState;
	import weave.api.ui.IPlotter;
	import weave.api.ui.IPlotterWithGeometries;
	import weave.api.ui.ITextPlotter;
	import weave.compiler.StandardLib;
	import weave.core.LinkableBoolean;
	import weave.core.LinkableHashMap;
	import weave.core.LinkableNumber;
	import weave.core.LinkableString;
	import weave.core.SessionManager;
	import weave.core.StageUtils;
	import weave.primitives.Bounds2D;
	import weave.primitives.GeneralizedGeometry;
	import weave.primitives.ZoomBounds;
	import weave.utils.NumberUtils;
	import weave.utils.PlotterUtils;
	import weave.utils.SpatialIndex;
	import weave.utils.ZoomUtils;

	/**
	 * This is a container for a list of PlotLayers
	 * 
	 * @author adufilie
	 */
	public class PlotManager implements ILinkableObject
	{
		public var debug:Boolean = false;
		
		public function PlotManager()
		{
			// zoom depends on plotters and layerSettings
			plotters.addImmediateCallback(this, updateZoom);
			layerSettings.addImmediateCallback(this, updateZoom);
			layerSettings.addImmediateCallback(this, refreshLayers);
			getCallbackCollection(zoomBounds).addImmediateCallback(this, refreshLayers);
			
			plotters.childListCallbacks.addImmediateCallback(this, handlePlottersList);
			layerSettings.childListCallbacks.addImmediateCallback(this, handleSettingsList);
			
			(WeaveAPI.SessionManager as SessionManager).excludeLinkableChildFromSessionState(this, marginBottomNumber);
			(WeaveAPI.SessionManager as SessionManager).excludeLinkableChildFromSessionState(this, marginTopNumber);
			(WeaveAPI.SessionManager as SessionManager).excludeLinkableChildFromSessionState(this, marginLeftNumber);
			(WeaveAPI.SessionManager as SessionManager).excludeLinkableChildFromSessionState(this, marginRightNumber);
			
			WeaveAPI.StageUtils.addEventCallback(Event.FRAME_CONSTRUCTED, this, handleFrameConstructed);
			Weave.properties.filter_callbacks.addImmediateCallback(this, refreshLayers);
		}
		
		/**
		 * This bitmap contains the graphics generated by the plotters.
		 */
		public function get bitmap():Bitmap
		{
			if (shouldRender)
				refreshLayers(true);

			return _bitmap;
		}
		private const _bitmap:Bitmap = new Bitmap(null, PixelSnapping.ALWAYS, false);
		
		public const plotters:LinkableHashMap = registerLinkableChild(this, new LinkableHashMap(IPlotter));
		public const layerSettings:LinkableHashMap = registerLinkableChild(this, new LinkableHashMap(LayerSettings));
		public const zoomBounds:ZoomBounds = newLinkableChild(this, ZoomBounds, updateZoom, false); // must be immediate callback to avoid displaying a stretched map, for example
		
		//These variables hold the numeric values of the margins. They are removed from the session state after the values are set
		//This was done to support percent values
		public const marginRightNumber:LinkableNumber = registerLinkableChild(this, new LinkableNumber(0), updateZoom, true);
		public const marginLeftNumber:LinkableNumber = registerLinkableChild(this, new LinkableNumber(0), updateZoom, true);
		public const marginTopNumber:LinkableNumber = registerLinkableChild(this, new LinkableNumber(0), updateZoom, true);
		public const marginBottomNumber:LinkableNumber = registerLinkableChild(this, new LinkableNumber(0), updateZoom, true);
		
		//These values take a string which could be a number value or a percentage value. The string is evaluated and 
		//the above set of margin values (marginTopNumber, margingBottomNumber...) are set with the correct numeric value
		public const marginRight:LinkableString = registerLinkableChild(this, new LinkableString('0', NumberUtils.verifyNumberOrPercentage), updateZoom, true);
		public const marginLeft:LinkableString = registerLinkableChild(this, new LinkableString('0', NumberUtils.verifyNumberOrPercentage), updateZoom, true);
		public const marginTop:LinkableString = registerLinkableChild(this, new LinkableString('0', NumberUtils.verifyNumberOrPercentage), updateZoom, true);
		public const marginBottom:LinkableString = registerLinkableChild(this, new LinkableString('0', NumberUtils.verifyNumberOrPercentage), updateZoom, true);
		
		public const minScreenSize:LinkableNumber = registerLinkableChild(this, new LinkableNumber(128), updateZoom, true);
		public const minZoomLevel:LinkableNumber = registerLinkableChild(this, new LinkableNumber(0), updateZoom, true);
		public const maxZoomLevel:LinkableNumber = registerLinkableChild(this, new LinkableNumber(18), updateZoom, true);
		public const enableFixedAspectRatio:LinkableBoolean = registerLinkableChild(this, new LinkableBoolean(false), updateZoom, true);
		public const enableAutoZoomToExtent:LinkableBoolean = registerLinkableChild(this, new LinkableBoolean(true), updateZoom, true);
		public const enableAutoZoomToSelection:LinkableBoolean = registerLinkableChild(this, new LinkableBoolean(false), updateZoom, true);
		public const includeNonSelectableLayersInAutoZoom:LinkableBoolean = registerLinkableChild(this, new LinkableBoolean(false), updateZoom, true);

		public const overrideXMin:LinkableNumber = registerLinkableChild(this, new LinkableNumber(NaN), updateZoom, true);
		public const overrideYMin:LinkableNumber = registerLinkableChild(this, new LinkableNumber(NaN), updateZoom, true);
		public const overrideXMax:LinkableNumber = registerLinkableChild(this, new LinkableNumber(NaN), updateZoom, true);
		public const overrideYMax:LinkableNumber = registerLinkableChild(this, new LinkableNumber(NaN), updateZoom, true);
		
		/**
		 * This is the collective data bounds of all the selectable plot layers.
		 */
		public const fullDataBounds:IBounds2D = new Bounds2D();
		
		private var _unscaledWidth:uint = 0;
		private var _unscaledHeight:uint = 0;
		
		// reusable temporary objects
		private const tempPoint:Point = new Point();
		private const tempBounds:IBounds2D = new Bounds2D();
		private const tempScreenBounds:IBounds2D = new Bounds2D();
		private const tempDataBounds:IBounds2D = new Bounds2D();
		
		private var _name_to_PlotTask_Array:Object = {}; // name -> Array of PlotTask
		private var _name_to_SpatialIndex:Object = {}; // name -> SpatialIndex
		
		/**
		 * This function gets called by updateZoom and updates fullDataBounds.
		 */
		protected function updateFullDataBounds():void
		{
			tempBounds.copyFrom(fullDataBounds);
			fullDataBounds.reset();

			for each (var name:String in plotters.getNames(IPlotter))
			{
				var settings:LayerSettings = layerSettings.getObject(name) as LayerSettings;
				
				// skip excluded layers
				if (!includeNonSelectableLayersInAutoZoom.value && !settings.selectable.value)
					continue;
				
				// skip invisible layers
				if (!settings.visible.value)
					continue;
				
				var spatialIndex:SpatialIndex = _name_to_SpatialIndex[name] as SpatialIndex;
				fullDataBounds.includeBounds(spatialIndex.collectiveBounds);
				
				var plotter:IPlotter = plotters.getObject(name) as IPlotter;
				plotter.getBackgroundDataBounds(tempDataBounds);
				fullDataBounds.includeBounds(tempDataBounds);
			}
			// ----------------- hack --------------------
			if (hack_adjustFullDataBounds != null)
				hack_adjustFullDataBounds();
			// -------------------------------------------
			
			if (!tempBounds.equals(fullDataBounds))
			{
				//trace('fullDataBounds changed',ObjectUtil.toString(fullDataBounds));
				getCallbackCollection(this).triggerCallbacks();
			}
		}
		
		/**
		 * This can be set to a function that will be called to adjust fullDataBounds whenever it is updated.
		 */		
		public var hack_adjustFullDataBounds:Function = null;
		/**
		 * This can be set to a function that will be called whenever updateZoom is called.
		 */
		private var hack_updateZoom_callbacks:Array = [];
		public function hack_onUpdateZoom(callback:Function):void
		{
			hack_updateZoom_callbacks.push(callback);
		}
		
		/**
		 * This function will update the fullDataBounds and zoomBounds based on the current state of the layers.
		 */
		protected function updateZoom():void
		{
			// make sure callbacks only trigger once
			getCallbackCollection(this).delayCallbacks();
			getCallbackCollection(zoomBounds).delayCallbacks();
			//trace('begin updateZoom',ObjectUtil.toString(getSessionState(zoomBounds)));
			
			// make sure numeric margin values are correct
			marginBottomNumber.value = Math.round(NumberUtils.getNumberFromNumberOrPercent(marginBottom.value, _unscaledHeight));
			marginTopNumber.value = Math.round(NumberUtils.getNumberFromNumberOrPercent(marginTop.value, _unscaledHeight));
			marginLeftNumber.value = Math.round(NumberUtils.getNumberFromNumberOrPercent(marginLeft.value, _unscaledWidth));
			marginRightNumber.value = Math.round(NumberUtils.getNumberFromNumberOrPercent(marginRight.value, _unscaledWidth));
			
			updateFullDataBounds();
			
			// calculate new screen bounds in temp variable
			// default behaviour is to set screenBounds beginning from lower-left corner and ending at upper-right corner
			var left:Number = marginLeftNumber.value;
			var top:Number = marginTopNumber.value;
			var right:Number = _unscaledWidth - marginRightNumber.value;
			var bottom:Number = _unscaledHeight - marginBottomNumber.value;
			// set screenBounds beginning from lower-left corner and ending at upper-right corner
			//TODO: is other behavior required?
			tempScreenBounds.setBounds(left, bottom, right, top);
			if (left > right)
				tempScreenBounds.setWidth(0);
			if (top > bottom)
				tempScreenBounds.setHeight(0);
			// copy current dataBounds to temp variable
			zoomBounds.getDataBounds(tempDataBounds);
			
			// determine if dataBounds should be zoomed to fullDataBounds
			if (enableAutoZoomToExtent.value || tempDataBounds.isUndefined())
			{
				if (!fullDataBounds.isEmpty())
					tempDataBounds.copyFrom(fullDataBounds);

				if (isFinite(overrideXMin.value))
					tempDataBounds.setXMin(overrideXMin.value);
				if (isFinite(overrideXMax.value))
					tempDataBounds.setXMax(overrideXMax.value);
				if (isFinite(overrideYMin.value))
					tempDataBounds.setYMin(overrideYMin.value);
				if (isFinite(overrideYMax.value))
					tempDataBounds.setYMax(overrideYMax.value);

				if (enableFixedAspectRatio.value)
				{
					var xScale:Number = tempDataBounds.getWidth() / tempScreenBounds.getXCoverage();
					var yScale:Number = tempDataBounds.getHeight() / tempScreenBounds.getYCoverage();
					// keep greater data-to-pixel ratio because we want to zoom out if necessary
					if (xScale > yScale)
						tempDataBounds.setHeight(tempScreenBounds.getYCoverage() * xScale);
					if (yScale > xScale)
						tempDataBounds.setWidth(tempScreenBounds.getXCoverage() * yScale);
				}
			}
			
			var overrideBounds:Boolean = isFinite(overrideXMin.value) || isFinite(overrideXMax.value)
										|| isFinite(overrideYMin.value) || isFinite(overrideYMax.value);
			if (!tempScreenBounds.isEmpty() && !overrideBounds)
			{
				//var minSize:Number = Math.min(minScreenSize.value, tempScreenBounds.getXCoverage(), tempScreenBounds.getYCoverage());
				
				if (!tempDataBounds.isUndefined() && !fullDataBounds.isUndefined())
				{
					// Enforce pan restrictions on tempDataBounds.
					// Center of visible dataBounds should be a point inside fullDataBounds.
					fullDataBounds.constrainBoundsCenterPoint(tempDataBounds);
					//fullDataBounds.constrainBounds(tempDataBounds);
				}
			}
			
			// save new bounds
			zoomBounds.setBounds(tempDataBounds, tempScreenBounds, enableFixedAspectRatio.value);
			if (enableAutoZoomToSelection.value)
				zoomToSelection();
			
			// ----------------- hack --------------------
			for each (var callback:Function in hack_updateZoom_callbacks)
				callback();
			// -------------------------------------------
			
			getCallbackCollection(zoomBounds).resumeCallbacks();
			getCallbackCollection(this).resumeCallbacks();
		}
		
		/**
		 * This function will zoom the visualization to the bounds corresponding to a list of keys.
		 * @param keys An Array of IQualifiedKey objects, or null to get them from the current selection.
		 * @param zoomMarginPercent The percent of width and height to reserve for space around the zoomed area.
		 */
		public function zoomToSelection(keys:Array = null, zoomMarginPercent:Number = 0.2):void
		{
			if (!keys)
			{
				var selection:IKeySet = Weave.defaultSelectionKeySet;
				var probe:IKeySet = Weave.defaultProbeKeySet;
				var alwaysHighlight:IKeySet = Weave.alwaysHighlightKeySet;
				keys = selection.keys;
				if (keys.length == 0)
					keys = probe.keys;
				if (keys.length == 0)
					keys = alwaysHighlight.keys;
			}
			
			// get the bounds containing all the records on all the layers
			tempBounds.reset();
			var names:Array = plotters.getNames(IPlotter);
			for each (var key:* in keys)
			{
				// support for generic objects coming from JavaScript
				if (!(key is IQualifiedKey))
					key = WeaveAPI.QKeyManager.getQKey(key.keyType, key.localName);
				
				for each (var name:String in names)
				{
					var spatialIndex:SpatialIndex = _name_to_SpatialIndex[name] as SpatialIndex;
					for each (var bounds:IBounds2D in spatialIndex.getBoundsFromKey(key))
						tempBounds.includeBounds(bounds);
				}
			}
			
			// make sure callbacks only trigger once.
			getCallbackCollection(zoomBounds).delayCallbacks();
			
			if (tempBounds.isEmpty())
			{
				zoomBounds.getDataBounds(tempDataBounds);
				tempDataBounds.setCenter(tempBounds.getXCenter(), tempBounds.getYCenter());
				zoomBounds.setDataBounds(tempDataBounds);
			}
			else
			{
				// zoom to that bounds, expanding the area to keep the fixed aspect ratio
				// if tempBounds is undefined and enableAutoZoomToExtent is enabled, this will zoom to the full extent.
				zoomBounds.setDataBounds(tempBounds, true);
				
				// zoom out to include the specified margin
				zoomBounds.getDataBounds(tempBounds);
				var scale:Number = 1 / (1 - zoomMarginPercent);
				tempBounds.setWidth(tempBounds.getWidth() * scale);
				tempBounds.setHeight(tempBounds.getHeight() * scale);
				zoomBounds.setDataBounds(tempBounds);
			}
			getCallbackCollection(zoomBounds).resumeCallbacks();
		}

		/**
		 * This function gets the current zoom level as defined in ZoomUtils.
		 * @return The current zoom level.
		 * @see weave.utils.ZoomUtils#getZoomLevel
		 */
		public function getZoomLevel():Number
		{
			zoomBounds.getDataBounds(tempDataBounds);
			zoomBounds.getScreenBounds(tempScreenBounds);
			var minSize:Number = Math.min(minScreenSize.value, tempScreenBounds.getXCoverage(), tempScreenBounds.getYCoverage());
			var zoomLevel:Number = ZoomUtils.getZoomLevel(tempDataBounds, tempScreenBounds, fullDataBounds, minSize);
			return zoomLevel;
		}
		
		/**
		 * This function sets the zoom level as defined in ZoomUtils.
		 * @param newZoomLevel The new zoom level.
		 * @see weave.utils.ZoomUtils#getZoomLevel
		 */
		public function setZoomLevel(newZoomLevel:Number):void
		{
			newZoomLevel = StandardLib.roundSignificant(newZoomLevel);
			var currentZoomLevel:Number = getZoomLevel();
			var newConstrainedZoomLevel:Number = StandardLib.constrain(newZoomLevel, minZoomLevel.value, maxZoomLevel.value);
			if (newConstrainedZoomLevel != currentZoomLevel)
			{
				var scale:Number = 1 / Math.pow(2, newConstrainedZoomLevel - currentZoomLevel);
				if (!isNaN(scale) && scale != 0)
				{
					zoomBounds.getDataBounds(tempDataBounds);
					tempDataBounds.setWidth(tempDataBounds.getWidth() * scale);
					tempDataBounds.setHeight(tempDataBounds.getHeight() * scale);
					zoomBounds.setDataBounds(tempDataBounds);
				}
			}
		}
		
		/**
		 * This function sets the data bounds for zooming, but checks them against the min and max zoom first.
		 * @param bounds The bounds that zoomBounds should be set to.
		 * @see weave.primitives.ZoomBounds#setDataBounds()
		 */
		public function setCheckedZoomDataBounds(dataBounds:IBounds2D):void
		{
			// instead of calling zoomBounds.setDataBounds() directly, we use setZoomLevel() because it's easier to constrain between min and max zoom.
			
			zoomBounds.getScreenBounds(tempScreenBounds);
			var minSize:Number = Math.min(minScreenSize.value, tempScreenBounds.getXCoverage(), tempScreenBounds.getYCoverage());
			var newZoomLevel:Number = StandardLib.roundSignificant(
				StandardLib.constrain(
					ZoomUtils.getZoomLevel(dataBounds, tempScreenBounds, fullDataBounds, minSize),
					minZoomLevel.value,
					maxZoomLevel.value
				)
			);
			
			// stop if constrained zoom level doesn't change
			if (getZoomLevel() == newZoomLevel)
				return;
			
			var cc:ICallbackCollection = getCallbackCollection(zoomBounds);
			cc.delayCallbacks();
			
			setZoomLevel(newZoomLevel);
			zoomBounds.getDataBounds(tempDataBounds);
			if (tempDataBounds.isUndefined())
				tempDataBounds.copyFrom(dataBounds);
			else
				tempDataBounds.setCenter(dataBounds.getXCenter(), dataBounds.getYCenter());
			zoomBounds.setDataBounds(tempDataBounds);

			// ----------------- hack --------------------
			for each (var callback:Function in hack_updateZoom_callbacks)
				callback();
			// -------------------------------------------
			
			cc.resumeCallbacks();
		}
		
		/**
		 * This function will get all the unique keys that overlap each geometry specified by
		 * simpleGeometries. 
		 * @param simpleGeometries
		 * @param LayerName optional parameter, when specified, will only return the overlapping geometries for the given layer.
		 * @return An array of keys.
		 */		
		public function getKeysOverlappingGeometry(simpleGeometries:Array, layerName:String = null):Array
		{
			var key:IQualifiedKey;
			var keys:Dictionary = new Dictionary();
			var geometry:Object;
			
			var names:Array = layerName ? [layerName] : plotters.getNames();
			
			
			// Go through the layers and make a query for each layer
			for each (var name:String in names)
			{
				var spatialIndex:SpatialIndex = _name_to_SpatialIndex[name] as SpatialIndex;
				for each (geometry in simpleGeometries)
				{
					var simpleGeometry:ISimpleGeometry = geometry as ISimpleGeometry;	
					var queriedKeys:Array;
					
					if ( geometry is GeneralizedGeometry )
					{						
						var geometryAsSimpleGeometries:Array = (geometry as GeneralizedGeometry).getSimpleGeometries();
						queriedKeys = spatialIndex.getKeysGeometryOverlapGeometries(geometryAsSimpleGeometries);
					}
					else if (simpleGeometry)
					{
						queriedKeys = spatialIndex.getKeysGeometryOverlapGeometry(simpleGeometry);
					}
						
					// use the dictionary to handle duplicates
					for each (key in queriedKeys)
					{
						keys[key] = true;
					}
				}
			}
			
			var result:Array = [];
			for (var keyObj:* in keys)
				result.push(keyObj as IQualifiedKey);
			
			return result;
		}
		
		
		/**
		 * This function will return the overlapping in the destination layer overlapping keys
		 *
		 * @author fkamayou 
		 * @param SourceKeys Array of IQualifiedKey objects which overlap the geometries of the the source layer 
		 * @param SourceLayer The source layer specified by <code>LayerName</code>
		 * @param destinationLayer The destination layer specified by <code>LayerName</code>
		 *
		 * @return An array of IQualifiedKey objects which overlap the geometries of the destination layer.
		 **/
		public function getOverlappingKeysAcrossLayers(sourceKeys:Array, sourceLayer:String, destinationLayer:String):Array
		{
			sourceKeys = WeaveAPI.QKeyManager.convertToQKeys(sourceKeys);
			var simpleGeometriesInSourceLayer:Array = [];
			var simpleGeometry:ISimpleGeometry;
			var queriedKeys:Array = [];
			var keys:Dictionary = new Dictionary();
			
			// get plotter from sourceLayer
			var plotterFromSourceLayer:IPlotterWithGeometries = plotters.getObject(sourceLayer) as IPlotterWithGeometries;
			if (!plotterFromSourceLayer)
			{
				reportError(StandardLib.substitute('Plotter named "{0}" does not exist.', sourceLayer));
				return null;
			}
				
			// use the source keys to get a list of overlapping geometries on the destination layer.
			// Iterate over all the keys
			for each ( var key:IQualifiedKey in sourceKeys)
			{	
				simpleGeometriesInSourceLayer = plotterFromSourceLayer.getGeometriesFromRecordKey(key);			
				
				// use the dictionary to handle duplicates
				for each (key in getKeysOverlappingGeometry(simpleGeometriesInSourceLayer, destinationLayer))
				{
					keys[key] = true;
				}
			}
			var result:Array = [];
			for (var keyObj:* in keys)
				result.push(keyObj as IQualifiedKey);
			
			return result;
								
		}
		
		private function handleSettingsList():void
		{
			// when settings are removed, remove plotter
			var oldName:String = layerSettings.childListCallbacks.lastNameRemoved;
			plotters.removeObject(oldName);
			plotters.setNameOrder(layerSettings.getNames());
		}
		
		private function handlePlottersList():void
		{
			plotters.delayCallbacks();
			layerSettings.delayCallbacks();
			
			// when plotter is removed, remove settings
			var oldName:String = plotters.childListCallbacks.lastNameRemoved;
			if (oldName)
			{
				delete _name_to_SpatialIndex[oldName];
				delete _name_to_PlotTask_Array[oldName];
				layerSettings.removeObject(oldName);
			}
			
			var newName:String = plotters.childListCallbacks.lastNameAdded;
			if (newName)
			{
				var newPlotter:IPlotter = plotters.childListCallbacks.lastObjectAdded as IPlotter;
				var settings:LayerSettings = layerSettings.requestObject(newName, LayerSettings, plotters.objectIsLocked(newName));
				
				// TEMPORARY SOLUTION until we start using VisToolGroup
				newPlotter.filteredKeySet.keyFilter.targetPath = [Weave.DEFAULT_SUBSET_KEYFILTER];
//				copySessionState(settings.subsetFilter, newPlotter.filteredKeySet.keyFilter);
				
				var spatialIndex:SpatialIndex = _name_to_SpatialIndex[newName] = newDisposableChild(newPlotter, SpatialIndex);
				var tasks:Array = _name_to_PlotTask_Array[newName] = [];
				for each (var taskType:int in [PlotTask.TASK_TYPE_SUBSET, PlotTask.TASK_TYPE_SELECTION, PlotTask.TASK_TYPE_PROBE])
				{
					var plotTask:PlotTask = new PlotTask(taskType, newPlotter, spatialIndex, zoomBounds, settings);
					registerDisposableChild(newPlotter, plotTask); // plotter is owner of task
					registerLinkableChild(this, plotTask); // task affects busy status of PlotManager
					tasks.push(plotTask);
					// set initial size
					plotTask.setBitmapDataSize(_unscaledWidth, _unscaledHeight);
					
					// when the plot task triggers callbacks, we need to render the layered visualization
					getCallbackCollection(plotTask).addImmediateCallback(this, refreshLayers);
				}
				setupBitmapFilters(newPlotter, settings, tasks[0], tasks[1], tasks[2]);
				// when spatial index is recreated, we need to update zoom
				spatialIndex.addImmediateCallback(this, updateZoom);
				
				if (newPlotter is ITextPlotter)
					settings.hack_useTextBitmapFilters = true;
			}
			
			layerSettings.setNameOrder(plotters.getNames());
			
			plotters.resumeCallbacks();
			layerSettings.resumeCallbacks();
		}
		
		private function setupBitmapFilters(plotter:IPlotter, settings:LayerSettings, subsetTask:PlotTask, selectionTask:PlotTask, probeTask:PlotTask):void
		{
			var updateFilters:Function = function():void
			{
				var keySet:IKeySet = settings.selectionFilter.internalObject as IKeySet;
				if (settings.selectable.value && keySet && keySet.keys.length) // selection
				{
					subsetTask.completedBitmap.alpha = Weave.properties.selectionAlphaAmount.value;
					subsetTask.bufferBitmap.alpha = Weave.properties.selectionAlphaAmount.value;
					
					if (Weave.properties.enableBitmapFilters.value)
					{
						subsetTask.completedBitmap.filters = [Weave.properties.filter_selectionBlur];
						subsetTask.bufferBitmap.filters = [Weave.properties.filter_selectionBlur];
					}
					else
					{
						subsetTask.completedBitmap.filters = null;
						subsetTask.bufferBitmap.filters = null;
					}
				}
				else // no selection
				{
					subsetTask.completedBitmap.alpha = 1.0;
					subsetTask.bufferBitmap.alpha = 1.0;
					subsetTask.completedBitmap.filters = null;
					subsetTask.bufferBitmap.filters = null;
				}
				
				if (Weave.properties.enableBitmapFilters.value)
				{
					selectionTask.completedBitmap.filters = [Weave.properties.filter_selectionShadow];
					selectionTask.bufferBitmap.filters = [Weave.properties.filter_selectionShadow];
					var inner:GlowFilter = plotter is ITextPlotter
						? Weave.properties.filter_probeGlowInnerText
						: Weave.properties.filter_probeGlowInner;
					probeTask.completedBitmap.filters = [inner, Weave.properties.filter_probeGlowOuter];
					probeTask.bufferBitmap.filters = [inner, Weave.properties.filter_probeGlowOuter];
				}
				else
				{
					selectionTask.completedBitmap.filters = null;
					selectionTask.bufferBitmap.filters = null;
					probeTask.completedBitmap.filters = [Weave.properties.filter_selectionShadow];
					probeTask.bufferBitmap.filters = [Weave.properties.filter_selectionShadow];
				}
			};
			settings.selectable.addImmediateCallback(plotter, updateFilters);
			getCallbackCollection(settings.selectionFilter).addImmediateCallback(plotter, updateFilters);
			Weave.properties.filter_callbacks.addImmediateCallback(plotter, updateFilters);
			updateFilters();
		}
		
		/**
		 * This function must be called to change the size of the bitmap data.
		 */
		public function setBitmapDataSize(unscaledWidth:uint, unscaledHeight:uint):void
		{
			if (_unscaledWidth != unscaledWidth || _unscaledHeight != unscaledHeight)
			{
				_unscaledWidth = unscaledWidth;
				_unscaledHeight = unscaledHeight;
				
				_frameCountSinceResize = 0;
				
				updateZoom();
				
				for each (var name:String in plotters.getNames(IPlotter))
				{
					for each (var plotTask:PlotTask in _name_to_PlotTask_Array[name])
					{
						plotTask.delayAsyncTask = true;
						plotTask.setBitmapDataSize(_unscaledWidth, _unscaledHeight);
					}
				}
			}
		}
		
		/**
		 * This returns true if the layer should be rendered and selectable/probeable
		 * @return true if the layer should be rendered and selectable/probeable
		 */
		public function layerShouldBeRendered(layerName:String):Boolean
		{
			var settings:LayerSettings = layerSettings.getObject(layerName) as LayerSettings;
			return settings.visible.value
				&& settings.isZoomBoundsWithinVisibleScale(zoomBounds);
		}
		
		public function hack_getSpatialIndex(layerName:String):SpatialIndex
		{
			return _name_to_SpatialIndex[layerName] as SpatialIndex;
		}
		
		private var _frameCountSinceResize:int = 0;
		
		private function handleFrameConstructed():void
		{
			if (++_frameCountSinceResize == 2)
			{
				for each (var name:String in plotters.getNames(IPlotter))
				{
					for each (var plotTask:PlotTask in _name_to_PlotTask_Array[name])
					{
						plotTask.delayAsyncTask = false;
					}
				}
			}
			
			if (shouldRender)
				refreshLayers(true);
		}
		
		private var prevFrame:int = 0;
		
		private var shouldRender:Boolean = false;
		
		public static var fade:Boolean = true; // Class('weave.visualization.layers.PlotManager').fade
		
		/**
		 * This gets called when a PlotTask triggers its callbacks.
		 */
		private function refreshLayers(immediately:Boolean = false):void
		{
			var now:int = getTimer();
			var tooEarly:Boolean = now < prevFrame + (WeaveAPI.StageUtils as StageUtils).getMaxComputationTimePerFrame()
				&& PlotterUtils.bitmapDataSizeEquals(_bitmap, _unscaledWidth, _unscaledHeight);
			if (!immediately || tooEarly)
			{
				shouldRender = true;
				return;
			}
			
			prevFrame = now;
			shouldRender = false;
			
			zoomBounds.getDataBounds(tempDataBounds);
			zoomBounds.getScreenBounds(tempScreenBounds);
			if (debug)
				debugTrace(this,'\n\tdata',String(tempDataBounds),'\n\tscreen',String(tempScreenBounds));
			
			PlotterUtils.setBitmapDataSize(_bitmap, _unscaledWidth, _unscaledHeight);
			if (_unscaledWidth && _unscaledHeight)
			{
				for each (var name:String in plotters.getNames(IPlotter))
				{
//					if (linkableObjectIsBusy(_name_to_SpatialIndex[name]))
//						continue;
					
					if (layerShouldBeRendered(name))
					{
						if (debug)
							debugTrace('render',name,getPlotter(name));
						var settings:LayerSettings = layerSettings.getObject(name) as LayerSettings;
						for each (var task:PlotTask in _name_to_PlotTask_Array[name])
						{
							var busy:Boolean = linkableObjectIsBusy(task);
							var completedReady:Boolean = !task.completedDataBounds.isUndefined();
							var alpha:Number = settings.alpha.value;
							
							if (completedReady)
							{
								if (debug)
									debugTrace(String(task),'completed','\n\tdata',String(task.completedDataBounds),'\n\tscreen',String(task.completedScreenBounds));
								
								copyScaledPlotGraphics(
									task.completedBitmap, task.completedDataBounds, task.completedScreenBounds,
									_bitmap.bitmapData, tempDataBounds, tempScreenBounds,
									alpha * (fade && busy ? 1 - task.progress : 1)
								);
							}
							else if (debug)
							{
								//debugTrace(String(task),'undefined',name);
							}
							
							if (fade && busy)
							{
								//TODO: this doesn't look good with transparency and overlapping completedBitmap and bufferBitmap
								//TODO: this is incorrect if the PlotTask hasn't cleared the previous bitmap yet.
								if (debug)
									debugTrace(String(task),'fade',task.progress,'\n\tdata',String(task.dataBounds),'\n\tscreen',String(task.screenBounds));
								
								shouldRender = true;
								
								copyScaledPlotGraphics(
									task.bufferBitmap, task.dataBounds, task.screenBounds,
									_bitmap.bitmapData, tempDataBounds, tempScreenBounds,
									alpha * (completedReady || task.progress == 0 ? .25 + .75 * task.progress : 1)
								);
							}
							
							if (debugMargins && !task.screenBounds.isUndefined())
							{
								var r:Rectangle = _bitmap.bitmapData.rect;
								var g:Graphics = tempShape.graphics;
								var sb:Bounds2D = task.screenBounds as Bounds2D;
								g.clear();
								g.lineStyle(1,0,1);
								g.beginFill(0xFFFFFF, 0.5);
								
								var ax:Array = [0, sb.xMin, sb.xMax, r.width];
								var ay:Array = [0, sb.yMax, sb.yMin, r.height];
								for (var ix:int = 0; ix < 3; ix++)
									for (var iy:int = 0; iy < 3; iy++)
										if (ix != 1 || iy != 1)
											g.drawRect(ax[ix], ay[iy], ax[ix+1]-ax[ix], ay[iy+1]-ay[iy]);
								
								_bitmap.bitmapData.draw(tempShape);
							}
						}
					}
					else if (debug)
					{
						//debugTrace('do not render',name);
					}
				}
			}
		}
		
		public var debugMargins:Boolean = false;
		private const tempShape:Shape = new Shape();
		
		private const _colorTransform:ColorTransform = new ColorTransform();
		private const _clipRect:Rectangle = new Rectangle();
		private const _matrix:Matrix = new Matrix();
		private function copyScaledPlotGraphics(source:DisplayObject, sourceDataBounds:IBounds2D, sourceScreenBounds:IBounds2D, destination:BitmapData, destinationDataBounds:IBounds2D, destinationScreenBounds:IBounds2D, alphaMultiplier:Number):void
		{
			// don't draw if offscreen
			if (!sourceDataBounds.overlaps(destinationDataBounds))
				return;
			
			var matrix:Matrix = null;
			var clipRect:Rectangle = null;
			if (!sourceDataBounds.equals(destinationDataBounds) || !sourceScreenBounds.equals(destinationScreenBounds))
			{
				matrix = _matrix;
				sourceScreenBounds.transformMatrix(sourceDataBounds, matrix, true);
				destinationDataBounds.transformMatrix(destinationScreenBounds, matrix, false);
				
				/*
				// Note: this still doesn't fix the following bug:
				// "Warning: Filter will not render.  The DisplayObject's filtered dimensions (8444, 2596) are too large to be drawn."
				clipRect = _clipRect;
				tempBounds.setBounds(0, 0, destination.width, destination.height);
				destinationScreenBounds.projectCoordsTo(tempBounds, destinationDataBounds);
				sourceDataBounds.projectCoordsTo(tempBounds, sourceScreenBounds);
				tempBounds.getRectangle(clipRect);
				*/
			}
			
			var colorTransform:ColorTransform = null;
			if (source.alpha != 1 || alphaMultiplier != 1)
			{
				colorTransform = _colorTransform;
				colorTransform.alphaMultiplier = source.alpha * alphaMultiplier;
			}

			// smoothing does not seem to make a difference.
			destination.draw(source, matrix, colorTransform, null, clipRect, false);
		}
		
		public function getPlotter(name:String):IPlotter
		{
			return plotters.getObject(name) as IPlotter;
		}
		public function getLayerSettings(name:String):LayerSettings
		{
			return layerSettings.getObject(name) as LayerSettings;
		}
		
		//-------------------------------------------------------------------------------------------------
		
		// backwards compatibility
		[Deprecated(replacement="zoomBounds")] public function set dataBounds(value:Object):void
		{
			setSessionState(zoomBounds, value);
		}
	}
}
